import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import '../models.dart';
import 'address_book_screen.dart';
import 'order_screen.dart';
import 'place_search.dart';
import 'share_codes.dart';
import 'tracking_screen.dart';
import 'widgets.dart';

enum _Mode { pickup, dropoffOnMap, summary }

const _maxStops = 10;

/// Accueil client / boutique : départ (épingle), une ou plusieurs adresses de livraison,
/// ordre de passage optimisé, choix de l'offre.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  final api = Api.instance;
  final _map = MapController();

  _Mode _mode = _Mode.pickup;
  LatLng _center = abidjan;
  bool _moving = false;
  Place? _centerPlace;
  bool _lookingUp = true;
  int? _eta;
  int _lookupSeq = 0;

  Place? _pickup;
  final List<StopDraft> _stops = [];
  Map<String, dynamic>? _quote;
  bool _quoting = false;
  String _vehicle = 'MOTO';

  Map<String, dynamic>? _active;

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

  Place get _centerAsPlace => Place(
    _centerPlace?.label ?? 'Point sur la carte',
    _centerPlace?.sublabel ?? '',
    _center,
  );

  // ---------- Départ / arrêts ----------

  Future<void> _searchPickup() async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(title: 'Départ', near: _center),
      ),
    );
    if (res is Place) {
      if (_mode == _Mode.summary) {
        setState(() => _pickup = res);
        _refreshQuote();
      } else {
        _moveTo(res);
      }
    }
  }

  /// Ajoute (ou remplace, si [replace] est fourni) une adresse de livraison
  Future<void> _addStop({int? replace}) async {
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
    StopDraft? draft;
    if (res is StopDraft) draft = res;
    if (res is Place) draft = StopDraft(res);
    if (draft != null) {
      setState(
        () => replace == null ? _stops.add(draft!) : _stops[replace] = draft!,
      );
      _showSummary();
    } else if (res == chooseOnMap) {
      if (replace != null) setState(() => _stops.removeAt(replace));
      setState(() => _mode = _Mode.dropoffOnMap);
      if (_stops.isNotEmpty) _map.move(_stops.last.place.point, 16);
      _lookupCenter();
    }
  }

  void _confirmDropoffOnMap() {
    hapticTap();
    setState(() => _stops.add(StopDraft(_centerAsPlace)));
    _showSummary();
  }

  Future<void> _stopActions(int i) async {
    final action = await showActions<String>(
      context,
      title: _stops[i].place.label,
      actions: [
        ('Changer l’adresse', 'edit', false),
        ('Supprimer cet arrêt', 'delete', true),
      ],
    );
    if (action == 'edit') _addStop(replace: i);
    if (action == 'delete') {
      setState(() => _stops.removeAt(i));
      _stops.isEmpty ? _backToPickup() : _refreshQuote();
    }
  }

  void _showSummary() {
    setState(() => _mode = _Mode.summary);
    _refreshQuote();
  }

  /// Devis : réordonne les arrêts selon l'ordre de passage optimisé
  Future<void> _refreshQuote() async {
    setState(() {
      _quote = null;
      _quoting = true;
    });
    try {
      final q = await api.quote(_pickup!.point, [
        for (final s in _stops) (point: s.place.point, cod: false),
      ]);
      if (!mounted) return;
      final order = (q['order'] as List).cast<int>();
      final reordered = [for (final i in order) _stops[i]];
      setState(() {
        _stops
          ..clear()
          ..addAll(reordered);
        _quote = q;
      });
      fitPoints(
        _map,
        [
          _pickup!.point,
          ..._stops.map((s) => s.place.point),
          ...latLngList(q['points']),
        ],
        padding: EdgeInsets.fromLTRB(
          50,
          120,
          50,
          MediaQuery.of(context).size.height * 0.05,
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _backToPickup() async {
    if (_stops.length > 1 &&
        !await confirm(
          context,
          'Effacer les ${_stops.length} adresses ?',
          ok: 'Effacer',
          destructive: true,
        )) {
      return;
    }
    setState(() {
      _mode = _Mode.pickup;
      _stops.clear();
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
          stops: _stops,
          quote: _quote!,
          vehicle: _vehicle,
        ),
      ),
    );
    if (created == null || !mounted) return;
    setState(() {
      _mode = _Mode.pickup;
      _stops.clear();
      _quote = null;
    });
    // Partage des codes aux destinataires (WhatsApp…), puis suivi
    await showShareCodes(context, created);
    if (!mounted) return;
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

  void _openAccount() => showAccountSheet(
    context,
    items: [
      (
        CupertinoIcons.cube_box_fill,
        letoOrange,
        'Mes livraisons',
        () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HistoryScreen(
              load: api.myDeliveries,
              onTap: (ctx, d) => Navigator.push(
                ctx,
                MaterialPageRoute(builder: (_) => TrackingScreen(d['id'])),
              ),
            ),
          ),
        ).then((_) => _loadActive()),
      ),
      (
        CupertinoIcons.book_fill,
        Palette.of(context).blue,
        'Carnet d’adresses',
        () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddressBookScreen()),
        ),
      ),
    ],
  );

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final points = _quote == null ? <LatLng>[] : latLngList(_quote!['points']);

    return Scaffold(
      backgroundColor: p.background,
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
                          pickupMarker(_pickup!.point),
                        for (var i = 0; i < _stops.length; i++)
                          stopMarker(context, _stops[i].place.point, i + 1),
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
                    title: 'Adresse ${_stops.length + 1}',
                    subtitle: 'Livrer ici',
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
                                ? MapButton(
                                    CupertinoIcons.person_crop_circle,
                                    onTap: _openAccount,
                                  )
                                : MapButton(
                                    CupertinoIcons.chevron_back,
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
                    bottom: 16,
                    child: MapButton(
                      CupertinoIcons.location_fill,
                      onTap: _locateMe,
                    ),
                  ),
              ],
            ),
          ),
          GlassPanel(
            children: switch (_mode) {
              _Mode.pickup => _pickupPanel(p),
              _Mode.dropoffOnMap => _dropoffOnMapPanel(p),
              _Mode.summary => _summaryPanel(p),
            },
          ),
        ],
      ),
    );
  }

  Widget _row({
    required Widget leading,
    required String caption,
    String? value,
    String placeholder = '',
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final p = Palette.of(context);
    final empty = value == null || value.isEmpty;
    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              hapticTap();
              onTap();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!empty)
                    Text(
                      caption,
                      style: TextStyles.footnote.copyWith(
                        color: p.secondaryLabel,
                      ),
                    ),
                  Text(
                    empty ? placeholder : value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: empty
                        ? TextStyles.body.copyWith(color: p.tertiaryLabel)
                        : TextStyles.headline.copyWith(color: p.label),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  Widget _numberDot(String label, Color color) => Container(
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    ),
  );

  List<Widget> _pickupPanel(Palette p) => [
    Text('Envoyer un colis', style: TextStyles.title1.copyWith(color: p.label)),
    const SizedBox(height: 8),
    _row(
      leading: IconBadge(
        CupertinoIcons.cube_box_fill,
        color: p.green,
        size: 32,
      ),
      caption: 'Prise en charge',
      value: _moving ? '…' : _centerPlace?.label,
      placeholder: 'Recherche de l’adresse…',
      onTap: _searchPickup,
    ),
    Divider(height: 1, indent: 44, color: p.separator),
    _row(
      leading: IconBadge(CupertinoIcons.flag_fill, color: letoOrange, size: 32),
      caption: 'Livraison',
      placeholder: 'Adresse de livraison',
      onTap: _addStop,
    ),
    const SizedBox(height: 4),
    Text(
      'Boutique ? Ajoutez plusieurs adresses : une seule tournée, un seul livreur.',
      style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
    ),
  ];

  List<Widget> _dropoffOnMapPanel(Palette p) => [
    Text('Où livrer ?', style: TextStyles.title2.copyWith(color: p.label)),
    const SizedBox(height: 6),
    _row(
      leading: _numberDot('${_stops.length + 1}', letoOrange),
      caption: 'Adresse ${_stops.length + 1}',
      value: _moving ? '…' : _centerPlace?.label,
    ),
    const SizedBox(height: 10),
    FilledButton(
      onPressed: _moving ? null : _confirmDropoffOnMap,
      child: const Text('Valider cette adresse'),
    ),
  ];

  List<Widget> _summaryPanel(Palette p) {
    final offers =
        (_quote?['offers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final selected = offers.where((o) => o['vehicle'] == _vehicle).firstOrNull;
    return [
      _row(
        leading: _numberDot('A', p.green),
        caption: 'Prise en charge',
        value: _pickup?.label,
        onTap: _searchPickup,
      ),
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.22,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < _stops.length; i++)
              _row(
                leading: _numberDot('${i + 1}', letoOrange),
                caption: _stops[i].name.isEmpty
                    ? 'Adresse ${i + 1}'
                    : _stops[i].name,
                value: _stops[i].place.label,
                onTap: () => _stopActions(i),
                trailing: Icon(
                  CupertinoIcons.ellipsis,
                  color: p.tertiaryLabel,
                  size: 20,
                ),
              ),
          ],
        ),
      ),
      if (_stops.length < _maxStops)
        _row(
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: letoOrange.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(CupertinoIcons.plus, color: letoOrange, size: 18),
          ),
          caption: '',
          placeholder: 'Ajouter une adresse',
          onTap: _addStop,
        ),
      const SizedBox(height: 8),
      SizedBox(
        height: 118,
        child: _quote == null
            ? const Center(child: CupertinoActivityIndicator())
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: offers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _OfferCard(
                  offer: offers[i],
                  eta: _eta,
                  selected: offers[i]['vehicle'] == _vehicle,
                  onTap: () {
                    hapticTap();
                    setState(() => _vehicle = offers[i]['vehicle']);
                  },
                ),
              ),
      ),
      if (_quote != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            [
              if (_stops.length > 1) '${_stops.length} arrêts · ordre optimisé',
              km(_quote!['distanceKm']),
              '~${_quote!['durationMin']} min',
            ].join(' · '),
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
        ),
      const SizedBox(height: 10),
      Row(
        children: [
          Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(
              color: p.green.withValues(alpha: 0.14),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.money_dollar_circle_fill, color: p.green),
                const SizedBox(width: 6),
                Text(
                  'Espèces',
                  style: TextStyles.headline.copyWith(color: p.green),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: selected == null || _quoting ? null : _continue,
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
    final p = Palette.of(context);
    final v = offer['vehicle'] as String;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 146,
        padding: const EdgeInsets.all(12),
        decoration: ShapeDecoration(
          color: selected ? letoOrange.withValues(alpha: 0.12) : p.fill,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: selected ? letoOrange : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  vehicleIcons[v],
                  size: 30,
                  color: selected ? letoOrange : p.label,
                ),
                const Spacer(),
                if (eta != null && v == 'MOTO')
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$eta min',
                      style: TextStyles.caption.copyWith(
                        color: p.label,
                        fontWeight: FontWeight.w700,
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
              style: TextStyles.subheadline.copyWith(
                color: p.label,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'dès ',
                    style: TextStyles.caption.copyWith(color: p.secondaryLabel),
                  ),
                  TextSpan(
                    text: fcfa(offer['prices']['SCHEDULED']),
                    style: TextStyles.title3.copyWith(
                      color: p.label,
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
    final stops = (d['stops'] as List? ?? []);
    final done = stops.where((s) => s['status'] != 'PENDING').length;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: const Color(0xF21C1C1E),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          shadows: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.two_wheeler, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Livraison en cours · ${statusLabels[d['status']]}',
                    style: TextStyles.subheadline.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    stops.length > 1
                        ? '$done/${stops.length} arrêts traités'
                        : '${d['pickupAddress']} → ${stops.isEmpty ? '' : stops.first['address']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.footnote.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_forward,
              color: Colors.white54,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
