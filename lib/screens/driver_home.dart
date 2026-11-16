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

/// Accueil livreur (style inDrive) : En ligne / Hors ligne, liste des courses,
/// course en cours, performance.
class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final api = Api.instance;
  final _scaffold = GlobalKey<ScaffoldState>();

  int _tab = 0;
  bool _online = false;
  LatLng? _me;
  Timer? _timer;
  Timer? _heartbeat;
  Timer? _clock; // rafraîchit les « il y a X sec. »
  StreamSubscription<Position>? _gps;

  List<Map<String, dynamic>> _available = [];
  List<Map<String, dynamic>> _mine = [];

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
    Realtime.instance.socket.on('deliveries:changed', _onDeliveriesChanged);
    SharedPreferences.getInstance().then((p) {
      if (p.getBool('driver_online') == true) _goOnline();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _stopGps();
    Realtime.instance.socket.off('deliveries:changed', _onDeliveriesChanged);
    super.dispose();
  }

  void _onDeliveriesChanged(dynamic _) => _load();

  Future<void> _load() async {
    try {
      final r = await Future.wait([api.available(), api.driverDeliveries()]);
      if (!mounted) return;
      setState(() {
        _available = r[0].cast<Map<String, dynamic>>();
        _mine = r[1].cast<Map<String, dynamic>>();
        // Les plus proches d'abord
        if (_me != null) {
          _available.sort((a, b) => _distanceTo(a).compareTo(_distanceTo(b)));
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  double _distanceTo(Map d) {
    final p = pointOf(d, 'pickup');
    return (_me == null || p == null) ? double.infinity : distanceKm(_me!, p);
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
    final accepted = await showCourseSheet(context, d, _me);
    await _load();
    if (accepted == true && mounted) {
      setState(() => _tab = 1);
      showInfo(context, 'Course acceptée — direction le point de départ');
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
      await _run(() => api.deliver(d['id'], code), 'Livraison terminée 🎉');
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffold,
      backgroundColor: Colors.white,
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
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  RoundButton(
                    Icons.menu,
                    onTap: () => _scaffold.currentState!.openDrawer(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _OnlineSwitch(
                      online: _online,
                      onTap: _online ? _goOffline : _goOnline,
                    ),
                  ),
                  const SizedBox(width: 12),
                  RoundButton(Icons.refresh, onTap: _load),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [_ordersTab(), _activeTab(), _performanceTab()],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Colors.white,
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _online && _available.isNotEmpty,
              label: Text('${_available.length}'),
              child: const Icon(Icons.list_alt),
            ),
            label: 'Courses',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _active.isNotEmpty,
              label: Text('${_active.length}'),
              child: const Icon(Icons.bolt),
            ),
            label: 'En cours',
          ),
          const NavigationDestination(
            icon: Icon(Icons.grid_view),
            label: 'Performance',
          ),
        ],
      ),
    );
  }

  // ----- Onglet 1 : commandes de course -----
  Widget _ordersTab() {
    if (!_online) {
      return _Empty(
        icon: Icons.power_settings_new,
        title: 'Vous êtes hors ligne',
        text: 'Passez en ligne pour recevoir les courses autour de vous.',
        action: FilledButton(
          onPressed: _goOnline,
          child: const Text('Passer en ligne'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _available.isEmpty
          ? ListView(
              children: const [
                _Empty(
                  icon: Icons.inbox_outlined,
                  title: 'Aucune course pour le moment',
                  text: 'Les nouvelles courses apparaissent ici en temps réel.',
                ),
              ],
            )
          : ListView.separated(
              itemCount: _available.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _OrderTile(
                d: _available[i],
                distance: _me == null ? null : _distanceTo(_available[i]),
                onTap: () => _openCourse(_available[i]),
              ),
            ),
    );
  }

  // ----- Onglet 2 : course en cours -----
  Widget _activeTab() {
    if (_active.isEmpty) {
      return _Empty(
        icon: Icons.bolt,
        title: 'Aucune course en cours',
        text: 'Acceptez une course dans l’onglet « Courses ».',
        action: OutlinedButton(
          onPressed: () => setState(() => _tab = 0),
          child: const Text('Voir les courses'),
        ),
      );
    }
    final d = _active.first;
    return _ActiveCourse(
      key: ValueKey('${d['id']}-${d['status']}'),
      d: d,
      me: _me,
      onPickup: () => _run(
        () => api.pickup(d['id']),
        'Colis récupéré — direction le destinataire',
      ),
      onDeliver: () => _askCode(d),
    );
  }

  // ----- Onglet 3 : performance -----
  Widget _performanceTab() {
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Performance',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.5,
            children: [
              _StatCard(
                'Courses aujourd’hui',
                '${todayList.length}',
                Icons.check_circle_outline,
              ),
              _StatCard(
                'Gains aujourd’hui',
                fcfa(sum(todayList, 'price')),
                Icons.trending_up,
              ),
              _StatCard(
                'Courses cette semaine',
                '${weekList.length}',
                Icons.calendar_today_outlined,
              ),
              _StatCard(
                'Gains cette semaine',
                fcfa(sum(weekList, 'price')),
                Icons.account_balance_wallet_outlined,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StatCard(
            'Encaissé pour l’entreprise aujourd’hui (paiement à la livraison)',
            fcfa(sum(todayList, 'codAmount')),
            Icons.payments_outlined,
            highlight: true,
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
        ],
      ),
    );
  }
}

/// Interrupteur En ligne / Hors ligne (pastille qui glisse)
class _OnlineSwitch extends StatelessWidget {
  final bool online;
  final VoidCallback onTap;
  const _OnlineSwitch({required this.online, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = online ? letoGreen : const Color(0xFFE53945);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: color, width: 2),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: online ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(21),
            ),
            child: Text(
              online ? 'En ligne' : 'Hors ligne',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ligne de la liste des courses (style inDrive)
class _OrderTile extends StatelessWidget {
  final Map<String, dynamic> d;
  final double? distance;
  final VoidCallback onTap;
  const _OrderTile({
    required this.d,
    required this.distance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cod = (d['codAmount'] ?? 0) as num;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 84,
              child: Column(
                children: [
                  Avatar(d['client']?['name'] ?? '?', radius: 28),
                  const SizedBox(height: 6),
                  Text(
                    d['client']?['name'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    timeAgo(d['createdAt']),
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (distance != null && distance!.isFinite)
                    Text(
                      '~${km(distance!)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
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
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${d['pickupAddress']} (${d['pickupCommune']})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${d['dropoffAddress']} (${d['dropoffCommune']})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (d['vehicleType'] != 'MOTO')
                        Pill(
                          vehicleLabels[d['vehicleType']]!,
                          bg: const Color(0xFFEDEDED),
                          fg: letoDark,
                          icon: vehicleIcons[d['vehicleType']],
                        ),
                      if (d['paymentMethod'] != 'CASH')
                        PaymentBadge(d['paymentMethod']),
                      if (cod > 0) CodBadge(cod),
                    ],
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

/// Course en cours : carte vers la prochaine étape + infos + action
class _ActiveCourse extends StatefulWidget {
  final Map<String, dynamic> d;
  final LatLng? me;
  final VoidCallback onPickup;
  final VoidCallback onDeliver;
  const _ActiveCourse({
    super.key,
    required this.d,
    required this.me,
    required this.onPickup,
    required this.onDeliver,
  });

  @override
  State<_ActiveCourse> createState() => _ActiveCourseState();
}

class _ActiveCourseState extends State<_ActiveCourse> {
  final _map = MapController();
  RouteInfo? _route;
  bool _ready = false;

  bool get _toPickup => widget.d['status'] == 'ACCEPTED';
  LatLng? get _target => pointOf(widget.d, _toPickup ? 'pickup' : 'dropoff');

  @override
  void initState() {
    super.initState();
    _loadRoute();
  }

  Future<void> _loadRoute() async {
    final from = widget.me ?? pointOf(widget.d, 'pickup');
    final to = _target;
    if (from == null || to == null) return;
    try {
      final r = await Api.instance.route(from, to);
      if (!mounted) return;
      setState(() => _route = r);
      if (_ready) {
        fitPoints(_map, [
          from,
          to,
          ...r.points,
        ], padding: const EdgeInsets.all(40));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final cod = (d['codAmount'] ?? 0) as num;
    final target = _target;
    final contactName = _toPickup
        ? (d['pickupContactName'] ?? d['client']?['name'] ?? '')
        : d['recipientName'];
    final contactPhone = _toPickup ? d['pickupPhone'] : d['recipientPhone'];
    final details = _toPickup ? d['pickupDetails'] : d['dropoffDetails'];
    final photo = _toPickup ? d['pickupPhotoUrl'] : d['dropoffPhotoUrl'];

    return Column(
      children: [
        SizedBox(
          height: 260,
          child: LetoMap(
            controller: _map,
            center: target ?? abidjan,
            zoom: 14,
            onReady: () {
              _ready = true;
              fitPoints(_map, [
                widget.me,
                target,
                ...?_route?.points,
              ], padding: const EdgeInsets.all(40));
            },
            layers: [
              if (_route != null)
                routeLayer(
                  _route!.points,
                  color: _toPickup
                      ? const Color(0xFF3D5AFE)
                      : const Color(0xFF2E7D32),
                ),
              MarkerLayer(
                markers: [
                  if (target != null) pointMarker(target, dropoff: !_toPickup),
                  if (widget.me != null) myMarker(widget.me!),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StatusSteps(d['status']),
              const SizedBox(height: 14),
              Text(
                _toPickup
                    ? 'Direction le point de départ'
                    : 'Direction le destinataire',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_route != null)
                Text(
                  '${_route!.durationMin} min · ${km(_route!.distanceKm)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 15),
                ),
              const SizedBox(height: 10),
              PointLine(
                dropoff: !_toPickup,
                title: _toPickup
                    ? '${d['pickupAddress']} (${d['pickupCommune']})'
                    : '${d['dropoffAddress']} (${d['dropoffCommune']})',
                detail: details,
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(14),
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
                            _toPickup ? 'Expéditeur' : 'Destinataire',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 13,
                            ),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: AddressPhoto(photo),
                ),
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
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  Pill(
                    'Course ${fcfa(d['price'])}',
                    bg: const Color(0xFFEDEDED),
                    fg: letoDark,
                  ),
                  PaymentBadge(d['paymentMethod']),
                  if (cod > 0) CodBadge(cod),
                ],
              ),
              if (!_toPickup && cod > 0)
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
                  backgroundColor: _toPickup ? letoDark : letoGreen,
                ),
                onPressed: _toPickup ? widget.onPickup : widget.onDeliver,
                child: Text(
                  _toPickup
                      ? 'J’ai récupéré le colis'
                      : 'Livrer · saisir le code',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;
  const _StatCard(this.label, this.value, this.icon, {this.highlight = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: highlight ? const Color(0xFFFFF1E5) : const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(icon, color: highlight ? const Color(0xFF9A4A00) : letoDark),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;
  const _Empty({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: Colors.black26),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}
