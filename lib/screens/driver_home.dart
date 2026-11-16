import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import '../realtime.dart';
import 'driver_course_sheet.dart';
import 'widgets.dart';

/// Accueil livreur (esprit Yango) : carte plein écran + panneau glissant
/// avec trois onglets : Courses, En cours, Gains.
class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final api = Api.instance;
  final _scaffold = GlobalKey<ScaffoldState>();
  final _map = MapController();
  final _sheet = DraggableScrollableController();

  int _tab = 0; // 0 Courses · 1 En cours · 2 Gains
  ScrollController? _sheetScroll;

  /// Change d'onglet et remonte en haut du panneau
  void _setTab(int i) {
    setState(() => _tab = i);
    if (_sheetScroll?.hasClients == true) _sheetScroll!.jumpTo(0);
  }

  bool _online = false;
  LatLng? _me;
  Timer? _timer;
  Timer? _heartbeat;
  Timer? _clock; // rafraîchit les « il y a X sec. »
  StreamSubscription<Position>? _gps;

  List<Map<String, dynamic>> _available = [];
  List<Map<String, dynamic>> _mine = [];
  Map<String, Map<String, dynamic>> _myOffers =
      {}; // deliveryId → ma proposition

  RouteInfo? _activeRoute;
  String? _activeRouteKey;

  List<Map<String, dynamic>> get _active => _mine
      .where((d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']))
      .toList();

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    _clock = Timer.periodic(
      const Duration(seconds: 15),
      (_) => mounted ? setState(() {}) : null,
    );
    final s = Realtime.instance.socket;
    s.on('deliveries:changed', _onDeliveriesChanged);
    s.on('offer:accepted', _onOfferAccepted);
    s.on('offer:rejected', _onOfferRejected);
    SharedPreferences.getInstance().then((p) {
      if (p.getBool('driver_online') == true) _goOnline();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _stopGps();
    final s = Realtime.instance.socket;
    s.off('deliveries:changed', _onDeliveriesChanged);
    s.off('offer:accepted', _onOfferAccepted);
    s.off('offer:rejected', _onOfferRejected);
    super.dispose();
  }

  void _onDeliveriesChanged(dynamic _) => _load();

  Future<void> _onOfferAccepted(dynamic _) async {
    await _load();
    if (!mounted) return;
    _setTab(1);
    showInfo(
      context,
      'Le client a accepté votre prix — direction le point de départ',
    );
  }

  void _onOfferRejected(dynamic _) {
    _load();
    if (mounted) {
      showInfo(context, 'Le client n’a pas retenu votre proposition');
    }
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        api.available(),
        api.driverDeliveries(),
        api.myOffers(),
      ]);
      if (!mounted) return;
      setState(() {
        _available = r[0].cast<Map<String, dynamic>>();
        _mine = r[1].cast<Map<String, dynamic>>();
        _myOffers = {
          for (final o in r[2].cast<Map<String, dynamic>>())
            o['deliveryId'] as String: o,
        };
        if (_me != null) {
          _available.sort((a, b) => _distanceTo(a).compareTo(_distanceTo(b)));
        }
      });
      _refreshActiveRoute();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  double _distanceTo(Map d) {
    final p = pointOf(d, 'pickup');
    return (_me == null || p == null) ? double.infinity : distanceKm(_me!, p);
  }

  /// Itinéraire vers la prochaine étape de la course en cours (dessiné sur la carte)
  Future<void> _refreshActiveRoute() async {
    if (_active.isEmpty) {
      if (_activeRoute != null) setState(() => _activeRoute = null);
      _activeRouteKey = null;
      return;
    }
    final d = _active.first;
    final to = pointOf(d, d['status'] == 'ACCEPTED' ? 'pickup' : 'dropoff');
    final from = _me ?? pointOf(d, 'pickup');
    if (from == null || to == null) return;
    final key = '${d['id']}-${d['status']}';
    if (key == _activeRouteKey) return;
    _activeRouteKey = key;
    try {
      final r = await api.route(from, to);
      if (!mounted) return;
      setState(() => _activeRoute = r);
      _fitMap([from, to, ...r.points]);
    } catch (_) {}
  }

  /// Cadre la carte au-dessus du panneau
  void _fitMap(List<LatLng?> pts) {
    final h = MediaQuery.of(context).size.height;
    fitPoints(_map, pts, padding: EdgeInsets.fromLTRB(50, 110, 50, h * 0.5));
  }

  // ---------- En ligne / Hors ligne ----------

  Future<void> _goOnline() async {
    final first = await myPosition();
    if (!mounted) return;
    if (first == null) {
      showError(context, 'Activez la localisation pour passer en ligne.');
      return;
    }
    setState(() => _online = true);
    (await SharedPreferences.getInstance()).setBool('driver_online', true);
    _sendPosition(first);
    _map.move(first, 14);
    if (devPosition == null) {
      _gps =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen(
            (p) => _sendPosition(LatLng(p.latitude, p.longitude)),
            onError: (_) {},
          );
    }
    // Toutes les 20 s même à l'arrêt, pour rester « en ligne »
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_me != null) _sendPosition(_me!);
    });
    _load();
  }

  Future<void> _goOffline() async {
    if (_active.isNotEmpty) {
      showError(
        context,
        'Terminez votre course en cours avant de passer hors ligne.',
      );
      return;
    }
    _stopGps();
    Realtime.instance.socket.emit('driver:offline');
    setState(() => _online = false);
    (await SharedPreferences.getInstance()).setBool('driver_online', false);
  }

  void _stopGps() {
    _gps?.cancel();
    _gps = null;
    _heartbeat?.cancel();
  }

  void _sendPosition(LatLng p) {
    if (mounted) setState(() => _me = p);
    Realtime.instance.socket.emit('driver:location', {
      'lat': p.latitude,
      'lng': p.longitude,
    });
  }

  // ---------- Actions ----------

  Future<void> _openCourse(Map<String, dynamic> d) async {
    final result = await showCourseSheet(
      context,
      d,
      _me,
      myOffer: _myOffers[d['id']],
    );
    await _load();
    if (!mounted) return;
    if (result == 'accepted') {
      _setTab(1);
      showInfo(context, 'Course acceptée — direction le point de départ');
    } else if (result == 'offered') {
      showInfo(
        context,
        'Proposition envoyée — en attente de la réponse du client',
      );
    }
  }

  Future<void> _run(Future<dynamic> Function() action, String success) async {
    try {
      await action();
      if (mounted) showInfo(context, success);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    await _load();
  }

  Future<void> _askCode(Map<String, dynamic> d) async {
    final ctrl = TextEditingController();
    final cod = (d['codAmount'] ?? 0) as num;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Code de livraison'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (cod > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Avez-vous encaissé ${fcfa(cod)} ?',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9A4A00),
                  ),
                ),
              ),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 28,
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
              ),
              decoration: const InputDecoration(
                hintText: '----',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) {
      await _run(
        () => api.deliver(d['id'], code),
        'Livraison terminée, bravo !',
      );
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final active = _active.isEmpty ? null : _active.first;
    final target = active == null
        ? null
        : pointOf(
            active,
            active['status'] == 'ACCEPTED' ? 'pickup' : 'dropoff',
          );

    return Scaffold(
      key: _scaffold,
      drawer: LetoDrawer(
        items: [
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Historique'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryScreen(load: api.driverDeliveries),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // ----- Carte -----
          LetoMap(
            controller: _map,
            layers: [
              if (_activeRoute != null)
                routeLayer(
                  _activeRoute!.points,
                  color: active?['status'] == 'ACCEPTED'
                      ? const Color(0xFF3D5AFE)
                      : const Color(0xFF2E7D32),
                ),
              MarkerLayer(
                markers: [
                  // Courses disponibles : étiquettes de prix au point de départ
                  if (active == null && _online)
                    for (final d in _available)
                      if (pointOf(d, 'pickup') != null)
                        Marker(
                          point: pointOf(d, 'pickup')!,
                          width: 96,
                          height: 38,
                          child: GestureDetector(
                            onTap: () => _openCourse(d),
                            child: _PriceTag(d['price']),
                          ),
                        ),
                  if (target != null)
                    pointMarker(
                      target,
                      dropoff: active!['status'] != 'ACCEPTED',
                    ),
                  if (_me != null) myMarker(_me!),
                ],
              ),
            ],
          ),
          // ----- Barre du haut -----
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  RoundButton(
                    Icons.menu,
                    onTap: () => _scaffold.currentState!.openDrawer(),
                  ),
                  const Spacer(),
                  _StatusPill(
                    online: _online,
                    onChanged: (v) => v ? _goOnline() : _goOffline(),
                  ),
                  const Spacer(),
                  RoundButton(
                    Icons.near_me_outlined,
                    onTap: () =>
                        _me != null ? _map.move(_me!, 15) : _goOnline(),
                  ),
                ],
              ),
            ),
          ),
          // ----- Panneau -----
          DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: 0.5,
            minChildSize: 0.18,
            maxChildSize: 0.92,
            snap: true,
            snapSizes: const [0.5],
            builder: (context, scroll) {
              _sheetScroll = scroll;
              return Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18)],
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    controller: scroll,
                    slivers: [
                      // Poignée + onglets toujours visibles en haut du panneau
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _SheetHeader(
                          _Tabs(
                            index: _tab,
                            labels: [
                              'Courses${_online && _available.isNotEmpty ? ' · ${_available.length}' : ''}',
                              'En cours${_active.isNotEmpty ? ' · ${_active.length}' : ''}',
                              'Gains',
                            ],
                            onChanged: _setTab,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate(switch (_tab) {
                            0 => _ordersTab(),
                            1 => _activeTab(),
                            _ => _gainsTab(),
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ----- Onglet Courses -----
  List<Widget> _ordersTab() {
    if (!_online) {
      return [
        const _Title('VOUS ÊTES HORS LIGNE'),
        const SizedBox(height: 6),
        const Text(
          'Passez en ligne pour recevoir les courses autour de vous.',
          style: TextStyle(color: Colors.black54, fontSize: 15),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _goOnline,
          icon: const Icon(Icons.power_settings_new),
          label: const Text('Passer en ligne'),
        ),
      ];
    }
    return [
      const _Title('COURSES DISPONIBLES'),
      const SizedBox(height: 4),
      Text(
        _available.isEmpty
            ? 'Aucune course pour le moment. Elles apparaissent ici en temps réel.'
            : 'En temps réel · les plus proches d’abord',
        style: const TextStyle(color: Colors.black54),
      ),
      const SizedBox(height: 14),
      for (final d in _available)
        _OrderCard(
          d: d,
          distance: _me == null ? null : _distanceTo(d),
          myOffer: _myOffers[d['id']],
          onTap: () => _openCourse(d),
        ),
    ];
  }

  // ----- Onglet En cours -----
  List<Widget> _activeTab() {
    if (_active.isEmpty) {
      return [
        const _Title('AUCUNE COURSE EN COURS'),
        const SizedBox(height: 6),
        const Text(
          'Acceptez une course ou proposez votre prix dans l’onglet « Courses ».',
          style: TextStyle(color: Colors.black54, fontSize: 15),
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: () => _setTab(0),
          child: const Text('Voir les courses'),
        ),
      ];
    }
    final d = _active.first;
    final toPickup = d['status'] == 'ACCEPTED';
    final cod = (d['codAmount'] ?? 0) as num;
    final contactName = toPickup
        ? (d['pickupContactName'] ?? d['client']?['name'] ?? '')
        : d['recipientName'];
    final contactPhone = toPickup ? d['pickupPhone'] : d['recipientPhone'];
    final photo = toPickup ? d['pickupPhotoUrl'] : d['dropoffPhotoUrl'];

    return [
      StatusSteps(d['status']),
      const SizedBox(height: 16),
      _Title(toPickup ? 'VERS LE DÉPART' : 'VERS LE DESTINATAIRE'),
      if (_activeRoute != null)
        Text(
          '${_activeRoute!.durationMin} min · ${km(_activeRoute!.distanceKm)}',
          style: const TextStyle(color: Colors.black54, fontSize: 15),
        ),
      const SizedBox(height: 12),
      PointLine(
        dropoff: !toPickup,
        title: toPickup
            ? '${d['pickupAddress']} (${d['pickupCommune']})'
            : '${d['dropoffAddress']} (${d['dropoffCommune']})',
        detail: toPickup ? d['pickupDetails'] : d['dropoffDetails'],
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Avatar(contactName, radius: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contactName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    toPickup ? 'Expéditeur' : 'Destinataire',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.phone, color: letoGreen, size: 18),
            const SizedBox(width: 4),
            SelectableText(
              contactPhone,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      if (photo != null) ...[
        const SizedBox(height: 10),
        Align(alignment: Alignment.centerLeft, child: AddressPhoto(photo)),
      ],
      if ((d['courierComment'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.chat_bubble_outline, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(d['courierComment'])),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          Pill(
            'Course ${fcfa(d['price'])}',
            bg: const Color(0xFFEDEDED),
            fg: letoDark,
          ),
          const CashPill(),
          if (cod > 0) CodBadge(cod),
        ],
      ),
      if (!toPickup && cod > 0)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Encaissez le montant avant de remettre le colis.',
            style: TextStyle(color: Color(0xFF9A4A00)),
          ),
        ),
      const SizedBox(height: 16),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: toPickup ? letoDark : letoGreen,
        ),
        onPressed: toPickup
            ? () => _run(
                () => api.pickup(d['id']),
                'Colis récupéré — direction le destinataire',
              )
            : () => _askCode(d),
        child: Text(
          toPickup ? 'J’ai récupéré le colis' : 'Livrer · saisir le code',
        ),
      ),
    ];
  }

  // ----- Onglet Gains -----
  List<Widget> _gainsTab() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final delivered = _mine
        .where((d) => d['status'] == 'DELIVERED' && d['deliveredAt'] != null)
        .toList();
    Iterable<Map<String, dynamic>> since(DateTime t) => delivered.where(
      (d) => DateTime.parse(d['deliveredAt']).toLocal().isAfter(t),
    );
    num sum(Iterable<Map<String, dynamic>> l, String f) =>
        l.fold<num>(0, (s, d) => s + (d[f] ?? 0));
    final todayList = since(today);
    final weekList = since(weekStart);

    return [
      const _Title('MES GAINS'),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: letoDark,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Aujourd’hui', style: TextStyle(color: Colors.white70)),
            Text(
              fcfa(sum(todayList, 'price')),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              '${todayList.length} course(s) livrée(s)',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _StatCard(
              'Cette semaine',
              fcfa(sum(weekList, 'price')),
              '${weekList.length} course(s)',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              'Encaissé pour l’entreprise',
              fcfa(sum(todayList, 'codAmount')),
              'aujourd’hui (paiement à la livraison)',
              highlight: true,
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      const Text(
        'Dernières courses',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      ...delivered.take(10).map((d) => DeliveryCard(d)),
      if (delivered.isEmpty)
        const Text(
          'Aucune course livrée pour l’instant.',
          style: TextStyle(color: Colors.grey),
        ),
    ];
  }
}

/// En-tête épinglé du panneau : poignée + onglets
class _SheetHeader extends SliverPersistentHeaderDelegate {
  final Widget tabs;
  _SheetHeader(this.tabs);

  @override
  double get minExtent => 92;
  @override
  double get maxExtent => 92;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
    child: Column(children: [const Handle(), const SizedBox(height: 14), tabs]),
  );

  @override
  bool shouldRebuild(_SheetHeader old) => true;
}

/// Grand titre façon Yango
class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
    ),
  );
}

/// Interrupteur En ligne / Hors ligne (pastille flottante)
class _StatusPill extends StatelessWidget {
  final bool online;
  final ValueChanged<bool> onChanged;
  const _StatusPill({required this.online, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final color = online ? letoGreen : const Color(0xFFE53945);
    return Material(
      color: Colors.white,
      elevation: 4,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () => onChanged(!online),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                online ? 'En ligne' : 'Hors ligne',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              Switch(
                value: online,
                activeTrackColor: letoGreen,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Onglets en pastilles
class _Tabs extends StatelessWidget {
  final int index;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _Tabs({
    required this.index,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFF1F1F1),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: i == index ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: i == index
                      ? const [BoxShadow(color: Colors.black12, blurRadius: 6)]
                      : null,
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: i == index ? FontWeight.w800 : FontWeight.w500,
                    color: i == index ? letoDark : Colors.black54,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Carte d'une course disponible
class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final double? distance;
  final Map<String, dynamic>? myOffer;
  final VoidCallback onTap;
  const _OrderCard({
    required this.d,
    required this.distance,
    required this.myOffer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cod = (d['codAmount'] ?? 0) as num;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      fcfa(d['price']),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (d['speed'] == 'EXPRESS')
                      const Pill(
                        'Express',
                        bg: Color(0xFFFFE0E0),
                        fg: Color(0xFFB71C1C),
                        icon: Icons.bolt,
                      ),
                    if (d['speed'] == 'SCHEDULED')
                      const Pill(
                        'Dans 2 h',
                        bg: Color(0xFFE3F2FD),
                        fg: Color(0xFF0D47A1),
                        icon: Icons.schedule,
                      ),
                    const Spacer(),
                    Icon(
                      vehicleIcons[d['vehicleType']],
                      color: letoDark,
                      size: 28,
                    ),
                  ],
                ),
                Text(
                  [
                    if (distance != null && distance!.isFinite)
                      'à ${km(distance!)}',
                    if (d['distanceKm'] != null)
                      'trajet ${km(d['distanceKm'])}',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 10),
                PointLine(
                  title: '${d['pickupAddress']} (${d['pickupCommune']})',
                ),
                PointLine(
                  dropoff: true,
                  title: '${d['dropoffAddress']} (${d['dropoffCommune']})',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Avatar(d['client']?['name'] ?? '?', radius: 14),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${d['client']?['name'] ?? ''} · ${timeAgo(d['createdAt'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (cod > 0) CodBadge(cod),
                  ],
                ),
                if (myOffer != null) ...[
                  const SizedBox(height: 10),
                  Pill(
                    'Votre proposition : ${fcfa(myOffer!['price'])} · en attente',
                    bg: letoOrange.withValues(alpha: 0.12),
                    fg: const Color(0xFF9A4A00),
                    icon: Icons.hourglass_top,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Étiquette de prix sur la carte
class _PriceTag extends StatelessWidget {
  final num price;
  const _PriceTag(this.price);

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: letoDark,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
    ),
    child: Text(
      fcfa(price),
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    ),
  );
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final bool highlight;
  const _StatCard(this.label, this.value, this.sub, {this.highlight = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: highlight ? const Color(0xFFFFF1E5) : const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        Text(sub, style: const TextStyle(color: Colors.black45, fontSize: 12)),
      ],
    ),
  );
}
