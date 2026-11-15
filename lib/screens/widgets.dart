import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';

// ======================= Carte =======================

/// Carte OpenStreetMap (gratuite, sans clé API)
class LetoMap extends StatelessWidget {
  final MapController? controller;
  final LatLng center;
  final double zoom;
  final List<Widget> layers;
  final void Function(MapCamera camera, bool hasGesture)? onMove;
  final VoidCallback? onReady;

  const LetoMap({
    super.key,
    this.controller,
    this.center = abidjan,
    this.zoom = 13,
    this.layers = const [],
    this.onMove,
    this.onReady,
  });

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        onPositionChanged: onMove,
        onMapReady: onReady,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'ci.leto.leto',
        ),
        ...layers,
      ],
    );
  }
}

/// Marqueur : vert = départ, orange = arrivée
Marker pin(LatLng p, {bool dropoff = false}) => Marker(
      point: p,
      width: 44,
      height: 44,
      alignment: Alignment.topCenter,
      child: Icon(Icons.location_on, size: 44, color: dropoff ? letoOrange : letoGreen),
    );

/// Marqueur du livreur (moto)
Marker driverMarker(LatLng p) => Marker(
      point: p,
      width: 46,
      height: 46,
      child: Container(
        decoration: BoxDecoration(
          color: letoDark,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)],
        ),
        child: const Icon(Icons.two_wheeler, color: Colors.white, size: 24),
      ),
    );

/// Ma position (point bleu)
Marker myMarker(LatLng p) => Marker(
      point: p,
      width: 24,
      height: 24,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
        ),
      ),
    );

/// Trait entre départ et arrivée (ligne droite)
Widget routeLine(LatLng a, LatLng b) => PolylineLayer(polylines: [
      Polyline(points: [a, b], color: letoDark.withValues(alpha: 0.7), strokeWidth: 4),
    ]);

/// Ajuste la carte pour voir les deux points
void fitRoute(MapController c, LatLng? a, LatLng? b) {
  if (a == null || b == null) return;
  c.fitCamera(CameraFit.bounds(
    bounds: LatLngBounds(a, b),
    padding: const EdgeInsets.fromLTRB(60, 100, 60, 60),
    maxZoom: 15,
  ));
}

/// Épingle fixe au centre de la carte (on déplace la carte dessous)
class CenterPin extends StatelessWidget {
  final bool dropoff;
  final String label;
  const CenterPin({super.key, this.dropoff = false, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = dropoff ? letoOrange : letoGreen;
    return IgnorePointer(
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -38),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: letoDark, borderRadius: BorderRadius.circular(20)),
              child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
            Container(width: 4, height: 18, color: letoDark),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ======================= Panneaux / boutons =======================

/// Panneau blanc arrondi en bas de l'écran
class BottomPanel extends StatelessWidget {
  final List<Widget> children;
  const BottomPanel({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [const Handle(), const SizedBox(height: 12), ...children],
        ),
      ),
    );
  }
}

class Handle extends StatelessWidget {
  const Handle({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(3)),
        ),
      );
}

/// Bouton rond flottant (menu, retour, ma position)
class RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const RoundButton(this.icon, {super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(12), child: Icon(icon, color: letoDark)),
      ),
    );
  }
}

/// Ligne d'adresse façon "D'où ? / Où ?"
class AddressTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool dropoff;
  final bool highlighted;
  final VoidCallback? onTap;
  const AddressTile(this.title,
      {super.key, this.subtitle, this.dropoff = false, this.highlighted = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: highlighted ? const Color(0xFFF3F4F6) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dropoff ? letoOrange : letoGreen,
                shape: dropoff ? BoxShape.rectangle : BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(subtitle!, style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ]),
            ),
            if (onTap != null) const Icon(Icons.chevron_right, color: Colors.grey),
          ]),
        ),
      ),
    );
  }
}

// ======================= Statuts =======================

const _statusColors = {
  'PENDING': Colors.amber,
  'ACCEPTED': Colors.blue,
  'PICKED_UP': Colors.deepPurple,
  'DELIVERED': Colors.green,
  'CANCELLED': Colors.grey,
};

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = _statusColors[status] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Text(statusLabels[status] ?? status,
          style: TextStyle(color: color.shade800, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// Étapes : Demandée → Acceptée → Récupérée → Livrée
class StatusSteps extends StatelessWidget {
  final String status;
  const StatusSteps(this.status, {super.key});

  static const _order = ['PENDING', 'ACCEPTED', 'PICKED_UP', 'DELIVERED'];
  static const _labels = ['Demandée', 'Acceptée', 'Récupérée', 'Livrée'];

  @override
  Widget build(BuildContext context) {
    final current = _order.indexOf(status);
    return Row(
      children: List.generate(_order.length, (i) {
        final done = i <= current;
        return Expanded(
          child: Column(children: [
            Container(
              height: 5,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: done ? letoGreen : Colors.black12,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 6),
            Text(_labels[i],
                style: TextStyle(fontSize: 11, color: done ? letoDark : Colors.grey, fontWeight: FontWeight.w600)),
          ]),
        );
      }),
    );
  }
}

/// Carte compacte d'une course (listes)
class DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback? onTap;
  final List<Widget> actions;
  final bool selected;
  const DeliveryCard(this.d, {super.key, this.onTap, this.actions = const [], this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: selected ? letoOrange.withValues(alpha: 0.08) : const Color(0xFFF7F7F8),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? letoOrange : Colors.transparent),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              StatusChip(d['status']),
              const Spacer(),
              Text(fcfa(d['price']), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 10),
            _point(false, d['pickupCommune'], d['pickupAddress']),
            const SizedBox(height: 6),
            _point(true, d['dropoffCommune'], '${d['dropoffAddress']} · ${d['recipientName']}'),
            if (actions.isNotEmpty) ...[const SizedBox(height: 12), ...actions],
          ]),
        ),
      ),
    );
  }

  Widget _point(bool dropoff, String commune, String detail) => Row(children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dropoff ? letoOrange : letoGreen,
            shape: dropoff ? BoxShape.rectangle : BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$commune  ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: detail, style: const TextStyle(color: Colors.grey)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]);
}

/// Menu latéral commun (client et livreur)
class LetoDrawer extends StatelessWidget {
  final List<Widget> items;
  const LetoDrawer({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final user = Api.instance.user ?? {};
    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: letoOrange,
                child: Text((user['name'] ?? '?').toString().substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(user['name'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(user['phone'] ?? '', style: const TextStyle(color: Colors.grey)),
                ]),
              ),
            ]),
          ),
          const Divider(),
          ...items,
          const Spacer(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Déconnexion'),
            onTap: () async {
              await Api.instance.logout();
              if (context.mounted) goHome(context);
            },
          ),
        ]),
      ),
    );
  }
}

/// Écran liste générique (historique client / livreur)
class HistoryScreen extends StatefulWidget {
  final Future<List<dynamic>> Function() load;
  final void Function(BuildContext, Map<String, dynamic>)? onTap;
  const HistoryScreen({super.key, required this.load, this.onTap});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await widget.load();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mes livraisons')),
      body: _items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: _items!.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 150),
                      Center(child: Text('Aucune livraison', style: TextStyle(color: Colors.grey))),
                    ])
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: _items!
                          .map((d) => DeliveryCard(
                                d,
                                onTap: widget.onTap == null ? null : () => widget.onTap!(context, d),
                              ))
                          .toList(),
                    ),
            ),
    );
  }
}
