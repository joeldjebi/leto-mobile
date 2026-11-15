import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';
import 'order_screen.dart';
import 'tracking_screen.dart';
import 'widgets.dart';

enum _Step { pickup, dropoff }

/// Accueil client : carte plein écran + épingle centrale pour choisir départ puis arrivée
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  final api = Api.instance;
  final _map = MapController();
  final _scaffold = GlobalKey<ScaffoldState>();

  _Step _step = _Step.pickup;
  LatLng _center = abidjan;
  bool _moving = false;
  LatLng? _pickup;
  Map<String, dynamic>? _active; // livraison en cours, s'il y en a une

  String get _centerCommune => nearestCommune(_center);

  @override
  void initState() {
    super.initState();
    _locateMe();
    _loadActive();
  }

  Future<void> _locateMe() async {
    final pos = await myPosition();
    if (pos != null && mounted) _map.move(pos, 16);
  }

  Future<void> _loadActive() async {
    try {
      final list = await api.myDeliveries();
      final active = list.cast<Map<String, dynamic>>().where(
            (d) => ['PENDING', 'ACCEPTED', 'PICKED_UP'].contains(d['status']),
          );
      if (mounted) setState(() => _active = active.isEmpty ? null : active.first);
    } catch (_) {}
  }

  void _confirmPickup() {
    setState(() {
      _pickup = _center;
      _step = _Step.dropoff;
    });
  }

  Future<void> _confirmDropoff() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => OrderScreen(pickup: _pickup!, dropoff: _center)),
    );
    if (result == null || !mounted) return;
    setState(() {
      _step = _Step.pickup;
      _pickup = null;
    });
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TrackingScreen(result['id'])));
    _loadActive();
  }

  void _back() {
    setState(() => _step = _Step.pickup);
    if (_pickup != null) _map.move(_pickup!, _map.camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final isPickup = _step == _Step.pickup;
    return Scaffold(
      key: _scaffold,
      drawer: LetaDrawer(items: [
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
                  onTap: (ctx, d) =>
                      Navigator.push(ctx, MaterialPageRoute(builder: (_) => TrackingScreen(d['id']))),
                ),
              ),
            ).then((_) => _loadActive());
          },
        ),
      ]),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            LetaMap(
              controller: _map,
              layers: [if (!isPickup && _pickup != null) MarkerLayer(markers: [pin(_pickup!)])],
              onMove: (camera, gesture) => setState(() {
                _center = camera.center;
                _moving = gesture;
              }),
            ),
            CenterPin(
              dropoff: !isPickup,
              label: _moving ? '...' : (isPickup ? 'Départ' : 'Arrivée'),
            ),
            // Boutons en haut
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    isPickup
                        ? RoundButton(Icons.menu, onTap: () => _scaffold.currentState!.openDrawer())
                        : RoundButton(Icons.arrow_back, onTap: _back),
                  ]),
                  if (_active != null) ...[
                    const SizedBox(height: 10),
                    _ActiveBanner(_active!, onTap: () async {
                      await Navigator.push(
                          context, MaterialPageRoute(builder: (_) => TrackingScreen(_active!['id'])));
                      _loadActive();
                    }),
                  ],
                ]),
              ),
            ),
            Positioned(right: 12, bottom: 30, child: RoundButton(Icons.my_location, onTap: _locateMe)),
          ]),
        ),
        BottomPanel(children: [
          Text(
            isPickup ? "D'où part le colis ?" : 'Où livrer le colis ?',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (!isPickup) AddressTile(nearestCommune(_pickup!), subtitle: 'Départ', onTap: _back),
          AddressTile(
            _centerCommune,
            subtitle: 'Déplacez la carte pour placer le point',
            dropoff: !isPickup,
            highlighted: true,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: isPickup ? _confirmPickup : _confirmDropoff,
            child: Text(isPickup ? 'Confirmer le départ' : "Confirmer l'arrivée"),
          ),
        ]),
      ]),
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
      color: letaDark,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.delivery_dining, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Livraison en cours · ${statusLabels[d['status']]}\n${d['pickupCommune']} → ${d['dropoffCommune']}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ]),
        ),
      ),
    );
  }
}
