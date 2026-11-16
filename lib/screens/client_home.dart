import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import 'order_screen.dart';
import 'place_search.dart';
import 'tracking_screen.dart';
import 'widgets.dart';

enum _Mode { pickup, dropoffOnMap, summary }

/// Accueil client : carte + épingle (départ), adresse de livraison, puis choix de l'offre.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  final api = Api.instance;
  final _map = MapController();
  final _scaffold = GlobalKey<ScaffoldState>();

  _Mode _mode = _Mode.pickup;
  LatLng _center = abidjan;
  bool _moving = false;
  Place? _centerPlace; // adresse du point sous l'épingle
  bool _lookingUp = true;
  int? _eta; // « Prise en charge ~X min »
  int _lookupSeq = 0;

  Place? _pickup;
  Place? _dropoff;
  Map<String, dynamic>? _quote;
  String _vehicle = 'MOTO';

  Map<String, dynamic>? _active; // livraison en cours

  @override
  void initState() {
    super.initState();
    _loadActive();
    _lookupCenter();
    _locateMe();
  }

  // ---------- Carte ----------

  Future<void> _locateMe() async {
    final pos = await myPosition();
    if (pos == null || !mounted) return;
    _map.move(pos, 16);
    _center = pos;
    _lookupCenter();
  }

  void _onMove(MapCamera camera, bool gesture) {
    _center = camera.center;
    if (gesture && !_moving) setState(() => _moving = true);
  }

  void _onMoveEnd() {
    if (_mode == _Mode.summary) return;
    setState(() => _moving = false);
    _lookupCenter();
  }

  /// Adresse du point central + délai de prise en charge
  Future<void> _lookupCenter() async {
    final seq = ++_lookupSeq;
    final p = _center;
    setState(() => _lookingUp = true);
    try {
      final placeF = api.reverse(p);
      final etaF = _mode == _Mode.pickup ? api.eta(p) : Future.value(_eta);
      final place = await placeF;
      final eta = await etaF;
      if (!mounted || seq != _lookupSeq) return;
      setState(() {
        _centerPlace = place;
        _eta = eta;
      });
    } catch (_) {
      // Pas bloquant : on garde l'ancienne adresse
    } finally {
      if (mounted && seq == _lookupSeq) setState(() => _lookingUp = false);
    }
  }

  void _moveTo(Place p) {
    _map.move(p.point, 17);
    _center = p.point;
    setState(() => _centerPlace = p);
    if (_mode == _Mode.pickup) {
      api.eta(p.point).then((e) => mounted ? setState(() => _eta = e) : null);
    }
  }

  // ---------- Étapes ----------

  Place get _centerAsPlace => Place(
    _centerPlace?.label ?? 'Point sur la carte',
    _centerPlace?.sublabel ?? '',
    _center,
  );

  Future<void> _searchPickup() async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlaceSearchScreen(title: 'Lieu de prise en charge', near: _center),
      ),
    );
    if (res is Place) _moveTo(res);
  }

  Future<void> _searchDropoff() async {
    _pickup ??= _centerAsPlace;
    if (_mode == _Mode.pickup) _pickup = _centerAsPlace;
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: 'Adresse de livraison',
          near: _pickup!.point,
          dropoff: true,
        ),
      ),
    );
    if (!mounted) return;
    if (res is Place) {
      _dropoff = res;
      _showSummary();
    } else if (res == chooseOnMap) {
      setState(() => _mode = _Mode.dropoffOnMap);
      _lookupCenter();
    }
  }

  void _confirmDropoffOnMap() {
    _dropoff = _centerAsPlace;
    _showSummary();
  }

  Future<void> _showSummary() async {
    setState(() {
      _mode = _Mode.summary;
      _quote = null;
    });
    try {
      final q = await api.quote(_pickup!.point, _dropoff!.point);
      if (!mounted) return;
      setState(() => _quote = q);
      final pts = (q['points'] as List)
          .map(
            (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList();
      fitPoints(_map, [
        _pickup!.point,
        _dropoff!.point,
        ...pts,
      ], padding: const EdgeInsets.fromLTRB(50, 120, 50, 40));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _backToPickup() {
    setState(() {
      _mode = _Mode.pickup;
      _dropoff = null;
      _quote = null;
    });
    if (_pickup != null) _moveTo(_pickup!);
  }

  Future<void> _continue() async {
    final created = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => OrderScreen(
          pickup: _pickup!,
          dropoff: _dropoff!,
          quote: _quote!,
          vehicle: _vehicle,
        ),
      ),
    );
    if (created == null || !mounted) return;
    _pickup = null;
    _backToPickup();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TrackingScreen(created['id'])),
    );
    _loadActive();
  }

  Future<void> _loadActive() async {
    try {
      final list = await api.myDeliveries();
      final active = list.cast<Map<String, dynamic>>().where(
        (d) => ['PENDING', 'ACCEPTED', 'PICKED_UP'].contains(d['status']),
      );
      if (mounted) {
        setState(() => _active = active.isEmpty ? null : active.first);
      }
    } catch (_) {}
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final points = _quote == null
        ? <LatLng>[]
        : (_quote!['points'] as List)
              .map(
                (p) =>
                    LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
              )
              .toList();

    return Scaffold(
      key: _scaffold,
      drawer: LetoDrawer(
        items: [
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Mes livraisons'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    load: api.myDeliveries,
                    onTap: (ctx, d) => Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => TrackingScreen(d['id']),
                      ),
                    ),
                  ),
                ),
              ).then((_) => _loadActive());
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                LetoMap(
                  controller: _map,
                  onMove: _onMove,
                  onMoveEnd: _onMoveEnd,
                  layers: [
                    if (_mode == _Mode.summary && points.isNotEmpty)
                      routeLayer(points),
                    MarkerLayer(
                      markers: [
                        if (_mode != _Mode.pickup && _pickup != null)
                          pointMarker(_pickup!.point),
                        if (_mode == _Mode.summary && _dropoff != null)
                          pointMarker(_dropoff!.point, dropoff: true),
                      ],
                    ),
                  ],
                ),
                if (_mode == _Mode.pickup)
                  CenterPin(
                    title: 'Prise en charge',
                    subtitle: _eta == null
                        ? 'Aucun livreur proche'
                        : '~$_eta min',
                    loading: _moving || _lookingUp,
                  ),
                if (_mode == _Mode.dropoffOnMap)
                  CenterPin(
                    dropoff: true,
                    title: 'Livraison',
                    subtitle: 'Ici',
                    loading: _moving,
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            _mode == _Mode.pickup
                                ? RoundButton(
                                    Icons.menu,
                                    onTap: () =>
                                        _scaffold.currentState!.openDrawer(),
                                  )
                                : RoundButton(
                                    Icons.arrow_back,
                                    onTap: _backToPickup,
                                  ),
                          ],
                        ),
                        if (_active != null && _mode == _Mode.pickup) ...[
                          const SizedBox(height: 10),
                          _ActiveBanner(
                            _active!,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      TrackingScreen(_active!['id']),
                                ),
                              );
                              _loadActive();
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_mode != _Mode.summary)
                  Positioned(
                    right: 12,
                    bottom: 20,
                    child: RoundButton(
                      Icons.near_me_outlined,
                      onTap: _locateMe,
                    ),
                  ),
              ],
            ),
          ),
          BottomPanel(
            children: switch (_mode) {
              _Mode.pickup => _pickupPanel(),
              _Mode.dropoffOnMap => _dropoffOnMapPanel(),
              _Mode.summary => _summaryPanel(),
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _pickupPanel() => [
    const Text(
      'ENVOYER UN COLIS',
      style: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
      ),
    ),
    const SizedBox(height: 6),
    AddressRow(
      caption: 'Prise en charge',
      value: _moving ? '…' : _centerPlace?.label,
      placeholder: 'Recherche de l’adresse…',
      onTap: _searchPickup,
    ),
    const Divider(indent: 58, height: 1),
    AddressRow(
      caption: 'Livraison',
      placeholder: 'Adresse de livraison',
      dropoff: true,
      onTap: _searchDropoff,
    ),
  ];

  List<Widget> _dropoffOnMapPanel() => [
    const Text(
      'Où livrer le colis ?',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 6),
    AddressRow(
      caption: 'Livraison',
      value: _moving ? '…' : _centerPlace?.label,
      dropoff: true,
      onTap: _searchDropoff,
    ),
    const SizedBox(height: 10),
    FilledButton(
      onPressed: _moving ? null : _confirmDropoffOnMap,
      child: const Text('Valider l’adresse de livraison'),
    ),
  ];

  List<Widget> _summaryPanel() {
    final offers =
        (_quote?['offers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final selected = offers.where((o) => o['vehicle'] == _vehicle).firstOrNull;
    return [
      AddressRow(
        caption: 'Prise en charge',
        value: _pickup?.label,
        onTap: _backToPickup,
      ),
      const Divider(indent: 58, height: 1),
      AddressRow(
        caption: 'Livraison',
        value: _dropoff?.label,
        dropoff: true,
        onTap: _searchDropoff,
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 132,
        child: _quote == null
            ? const Center(child: CircularProgressIndicator())
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: offers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _OfferCard(
                  offer: offers[i],
                  eta: _eta,
                  selected: offers[i]['vehicle'] == _vehicle,
                  onTap: () => setState(() => _vehicle = offers[i]['vehicle']),
                ),
              ),
      ),
      if (_quote != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${km(_quote!['distanceKm'])} · ~${_quote!['durationMin']} min de trajet',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          // Paiement en espèces uniquement
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.payments_outlined, color: letoGreen),
                SizedBox(width: 6),
                Text('Espèces', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: selected == null ? null : _continue,
              child: Text(
                selected == null
                    ? 'Calcul du prix…'
                    : 'Continuer · ${fcfa(selected['prices']['STANDARD'])}',
              ),
            ),
          ),
        ],
      ),
    ];
  }
}

/// Carte d'offre du carrousel (Moto, Voiture, Cargo)
class _OfferCard extends StatelessWidget {
  final Map<String, dynamic> offer;
  final int? eta;
  final bool selected;
  final VoidCallback onTap;
  const _OfferCard({
    required this.offer,
    required this.eta,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final v = offer['vehicle'] as String;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? letoOrange.withValues(alpha: 0.08)
              : const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? letoOrange : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  vehicleIcons[v],
                  size: 34,
                  color: selected ? letoOrange : letoDark,
                ),
                const Spacer(),
                if (eta != null && v == 'MOTO')
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$eta min',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              offer['label'],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'dès ', style: TextStyle(fontSize: 12)),
                  TextSpan(
                    text: fcfa(offer['prices']['SCHEDULED']),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveBanner extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback onTap;
  const _ActiveBanner(this.d, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: letoDark,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.delivery_dining, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Livraison en cours · ${statusLabels[d['status']]}\n${d['pickupAddress']} → ${d['dropoffAddress']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
