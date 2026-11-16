import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';

// ======================= Carte =======================

/// Carte OpenStreetMap (affichage). La recherche et les itinéraires passent par l'API (Google + OSM).
class LetoMap extends StatelessWidget {
  final MapController? controller;
  final LatLng center;
  final double zoom;
  final List<Widget> layers;
  final void Function(MapCamera camera, bool hasGesture)? onMove;
  final VoidCallback? onMoveEnd;
  final VoidCallback? onReady;

  const LetoMap({
    super.key,
    this.controller,
    this.center = abidjan,
    this.zoom = 13,
    this.layers = const [],
    this.onMove,
    this.onMoveEnd,
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
        onMapEvent: onMoveEnd == null
            ? null
            : (e) {
                if (e is MapEventMoveEnd ||
                    e is MapEventFlingAnimationEnd ||
                    e is MapEventDoubleTapZoomEnd) {
                  onMoveEnd!();
                }
              },
        onMapReady: onReady,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
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

/// Point A (départ) ou B (arrivée)
Marker pointMarker(LatLng p, {bool dropoff = false}) => Marker(
  point: p,
  width: 34,
  height: 34,
  child: Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: dropoff ? letoOrange : letoGreen,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
    ),
    child: Text(
      dropoff ? 'B' : 'A',
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w900,
        fontSize: 14,
      ),
    ),
  ),
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

/// Étiquette « 19 min · 8,5 km » posée sur la carte
Marker routeLabel(LatLng p, String text, Color color) => Marker(
  point: p,
  width: 120,
  height: 34,
  child: Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    ),
  ),
);

/// Tracé d'un itinéraire
Widget routeLayer(List<LatLng> points, {Color color = letoDark}) =>
    PolylineLayer(
      polylines: [
        Polyline(
          points: points,
          color: color,
          strokeWidth: 5,
          borderColor: Colors.white,
          borderStrokeWidth: 1.5,
        ),
      ],
    );

/// Ajuste la carte pour voir tous les points
void fitPoints(
  MapController c,
  List<LatLng?> points, {
  EdgeInsets padding = const EdgeInsets.fromLTRB(50, 110, 50, 50),
}) {
  final pts = points.whereType<LatLng>().toList();
  if (pts.length < 2) {
    if (pts.length == 1) c.move(pts.first, 15);
    return;
  }
  c.fitCamera(
    CameraFit.coordinates(coordinates: pts, padding: padding, maxZoom: 16),
  );
}

/// Épingle fixe au centre de la carte, avec une bulle (ex. « Prise en charge ~10 min »)
class CenterPin extends StatelessWidget {
  final bool dropoff;
  final String title;
  final String? subtitle;
  final bool loading;
  const CenterPin({
    super.key,
    this.dropoff = false,
    required this.title,
    this.subtitle,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = dropoff ? letoOrange : letoGreen;
    return IgnorePointer(
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -46),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 10),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        dropoff ? Icons.flag : Icons.two_wheeler,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                        loading
                            ? const SizedBox(
                                width: 40,
                                child: LinearProgressIndicator(minHeight: 3),
                              )
                            : Text(
                                subtitle ?? '',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(width: 3, height: 16, color: letoDark),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= Panneaux / boutons =======================

/// Panneau blanc arrondi en bas de l'écran
class BottomPanel extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  const BottomPanel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      padding: padding,
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
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(3),
      ),
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
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: letoDark),
        ),
      ),
    );
  }
}

/// Ligne d'adresse façon « Prise en charge / Adresse de livraison »
class AddressRow extends StatelessWidget {
  final String caption;
  final String? value;
  final String placeholder;
  final bool dropoff;
  final VoidCallback? onTap;
  const AddressRow({
    super.key,
    required this.caption,
    this.value,
    this.placeholder = '',
    this.dropoff = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value == null || value!.isEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: dropoff ? letoOrange.withValues(alpha: 0.12) : letoDark,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                dropoff ? Icons.flag : Icons.inventory_2,
                color: dropoff ? letoOrange : Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!empty)
                    Text(
                      caption,
                      style: const TextStyle(
                        color: Colors.black45,
                        fontSize: 13,
                      ),
                    ),
                  Text(
                    empty ? placeholder : value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: empty ? 18 : 17,
                      fontWeight: empty ? FontWeight.w400 : FontWeight.w600,
                      color: empty ? Colors.black38 : letoDark,
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

// ======================= Badges =======================

class Pill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  final IconData? icon;
  const Pill(
    this.text, {
    super.key,
    required this.bg,
    required this.fg,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

/// Paiement de la course : espèces uniquement
class CashPill extends StatelessWidget {
  const CashPill({super.key});

  @override
  Widget build(BuildContext context) => const Pill(
    'Espèces',
    bg: Color(0xFFE8F5E9),
    fg: Color(0xFF1B5E20),
    icon: Icons.payments_outlined,
  );
}

/// Badge « Encaisser 15 000 F » (paiement à la livraison)
class CodBadge extends StatelessWidget {
  final num amount;
  const CodBadge(this.amount, {super.key});

  @override
  Widget build(BuildContext context) => Pill(
    'Encaisser ${fcfa(amount)}',
    bg: const Color(0xFFFFE4CC),
    fg: const Color(0xFF9A4A00),
    icon: Icons.account_balance_wallet_outlined,
  );
}

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
    return Pill(
      statusLabels[status] ?? status,
      bg: color.withValues(alpha: 0.15),
      fg: color.shade800,
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
          child: Column(
            children: [
              Container(
                height: 5,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: done ? letoGreen : Colors.black12,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _labels[i],
                style: TextStyle(
                  fontSize: 11,
                  color: done ? letoDark : Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// Ligne A / B avec adresse et précisions
class PointLine extends StatelessWidget {
  final bool dropoff;
  final String title;
  final String? detail;
  const PointLine({
    super.key,
    this.dropoff = false,
    required this.title,
    this.detail,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dropoff ? letoOrange : letoGreen,
            shape: BoxShape.circle,
          ),
          child: Text(
            dropoff ? 'B' : 'A',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null && detail!.isNotEmpty)
                Text(
                  detail!,
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Carte compacte d'une course (historiques)
class DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback? onTap;
  const DeliveryCard(this.d, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFFF7F7F8),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusChip(d['status']),
                  const SizedBox(width: 6),
                  Pill(
                    vehicleLabels[d['vehicleType']] ?? '',
                    bg: const Color(0xFFEDEDED),
                    fg: letoDark,
                    icon: vehicleIcons[d['vehicleType']],
                  ),
                  const Spacer(),
                  Text(
                    fcfa(d['price']),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              PointLine(title: d['pickupAddress'], detail: d['pickupCommune']),
              PointLine(
                dropoff: true,
                title: d['dropoffAddress'],
                detail: '${d['dropoffCommune']} · ${d['recipientName']}',
              ),
              if ((d['codAmount'] ?? 0) > 0) ...[
                const SizedBox(height: 6),
                CodBadge(d['codAmount']),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Miniature de photo d'adresse (agrandissable)
class AddressPhoto extends StatelessWidget {
  final String path;
  const AddressPhoto(this.path, {super.key});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl(path);
    return GestureDetector(
      onTap: () => showDialog(
        context: context,
        builder: (_) =>
            Dialog(child: InteractiveViewer(child: Image.network(url))),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          url,
          width: 72,
          height: 72,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Container(width: 72, height: 72, color: Colors.black12),
        ),
      ),
    );
  }
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Avatar(user['name'] ?? '?', radius: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user['name'] ?? '',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          user['phone'] ?? '',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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
          ],
        ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final double radius;
  const Avatar(this.name, {super.key, this.radius = 22});

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: const Color(0xFFEDEDED),
    child: Text(
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
      style: TextStyle(
        color: letoDark,
        fontWeight: FontWeight.bold,
        fontSize: radius * 0.8,
      ),
    ),
  );
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
                  ? ListView(
                      children: const [
                        SizedBox(height: 150),
                        Center(
                          child: Text(
                            'Aucune livraison',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: _items!
                          .map(
                            (d) => DeliveryCard(
                              d,
                              onTap: widget.onTap == null
                                  ? null
                                  : () => widget.onTap!(context, d),
                            ),
                          )
                          .toList(),
                    ),
            ),
    );
  }
}
