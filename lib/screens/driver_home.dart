import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';
import '../realtime.dart';
import 'widgets.dart';

/// Accueil livreur : carte avec les courses disponibles + panneau glissant
class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final api = Api.instance;
  final _map = MapController();
  final _scaffold = GlobalKey<ScaffoldState>();
  Timer? _timer;
  Timer? _heartbeat;
  StreamSubscription<Position>? _gps;
  LatLng? _me; // ma position

  List<Map<String, dynamic>> _available = [];
  List<Map<String, dynamic>> _active = [];
  Map<String, dynamic>? _selected; // course mise en avant sur la carte

  @override
  void initState() {
    super.initState();
    _load();
    // Les nouvelles courses arrivent en temps réel ; le rafraîchissement périodique est un filet de sécurité
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    Realtime.instance.socket.on('deliveries:changed', _onDeliveriesChanged);
    _startGps();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heartbeat?.cancel();
    _gps?.cancel();
    Realtime.instance.socket.off('deliveries:changed', _onDeliveriesChanged);
    super.dispose();
  }

  void _onDeliveriesChanged(dynamic _) => _load();

  /// Envoie la position GPS du livreur au serveur (à chaque déplacement de 10 m,
  /// et toutes les 20 s même à l'arrêt pour rester « en ligne »)
  Future<void> _startGps() async {
    final first = await myPosition(); // demande aussi la permission
    if (!mounted) return;
    if (first != null) {
      _map.move(first, 13);
      _sendPosition(first);
    }
    _gps = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((p) => _sendPosition(LatLng(p.latitude, p.longitude)), onError: (_) {});
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_me != null) _sendPosition(_me!);
    });
  }

  void _sendPosition(LatLng p) {
    if (mounted) setState(() => _me = p);
    Realtime.instance.socket.emit('driver:location', {'lat': p.latitude, 'lng': p.longitude});
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([api.available(), api.driverDeliveries()]);
      if (!mounted) return;
      setState(() {
        _available = r[0].cast<Map<String, dynamic>>();
        _active = r[1]
            .cast<Map<String, dynamic>>()
            .where((d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']))
            .toList();
        // Garde la sélection à jour (ou l'efface si la course a disparu)
        final all = [..._active, ..._available];
        final id = _selected?['id'];
        _selected = id == null ? null : all.where((d) => d['id'] == id).firstOrNull;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _select(Map<String, dynamic> d) {
    setState(() => _selected = d);
    fitRoute(_map, pointOf(d, 'pickup'), pointOf(d, 'dropoff'));
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

  Future<void> _askCode(String id) async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Code de livraison'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.bold),
          decoration: const InputDecoration(hintText: '----', counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) await _run(() => api.deliver(id, code), 'Livraison terminée 🎉');
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    final a = sel == null ? null : pointOf(sel, 'pickup');
    final b = sel == null ? null : pointOf(sel, 'dropoff');

    // Marqueurs : toutes les courses disponibles (départs), ou la course sélectionnée
    final markers = sel != null
        ? [if (a != null) pin(a), if (b != null) pin(b, dropoff: true)]
        : [
            for (final d in _available)
              if (pointOf(d, 'pickup') != null)
                Marker(
                  point: pointOf(d, 'pickup')!,
                  width: 90,
                  height: 36,
                  child: GestureDetector(onTap: () => _select(d), child: _PriceTag(d['price'])),
                ),
          ];

    return Scaffold(
      key: _scaffold,
      drawer: LetoDrawer(items: [
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Historique'),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryScreen(load: api.driverDeliveries)));
          },
        ),
      ]),
      body: Stack(children: [
        LetoMap(
          controller: _map,
          layers: [
            if (a != null && b != null) routeLine(a, b),
            MarkerLayer(markers: [...markers, if (_me != null) myMarker(_me!)]),
          ],
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              sel == null
                  ? RoundButton(Icons.menu, onTap: () => _scaffold.currentState!.openDrawer())
                  : RoundButton(Icons.arrow_back, onTap: () => setState(() => _selected = null)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: letoGreen, borderRadius: BorderRadius.circular(24)),
                child: const Text('● En ligne', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.42,
          minChildSize: 0.18,
          maxChildSize: 0.9,
          builder: (context, scroll) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18)],
            ),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [
                  const Handle(),
                  const SizedBox(height: 14),
                  if (_active.isNotEmpty) ...[
                    const Text('Course en cours', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    for (final d in _active) _activeCard(d),
                    const SizedBox(height: 10),
                  ],
                  Text(
                    _available.isEmpty ? 'Aucune course pour le moment' : '${_available.length} course(s) disponible(s)',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('Nouvelles courses en temps réel', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  for (final d in _available)
                    DeliveryCard(
                      d,
                      selected: sel?['id'] == d['id'],
                      onTap: () => _select(d),
                      actions: [
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                          onPressed: () => _run(() => api.accept(d['id']), 'Course acceptée'),
                          child: const Text('Accepter'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _activeCard(Map<String, dynamic> d) {
    final accepted = d['status'] == 'ACCEPTED';
    return DeliveryCard(
      d,
      selected: true,
      onTap: () => _select(d),
      actions: [
        StatusSteps(d['status']),
        const SizedBox(height: 10),
        Text(
          accepted
              ? 'Récupérer chez : ${d['client']['name']} · ${d['pickupPhone']}'
              : 'Livrer à : ${d['recipientName']} · ${d['recipientPhone']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            backgroundColor: accepted ? letoDark : letoGreen,
          ),
          onPressed: accepted
              ? () => _run(() => api.pickup(d['id']), 'Colis récupéré')
              : () => _askCode(d['id']),
          child: Text(accepted ? 'J’ai récupéré le colis' : 'Livrer · saisir le code'),
        ),
      ],
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
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
        ),
        child: Text(fcfa(price), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );
}
