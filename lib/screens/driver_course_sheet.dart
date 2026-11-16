import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import 'widgets.dart';

/// Fiche d'une course disponible (style inDrive) : carte avec trajets
/// moi → A (bleu) et A → B (vert), détails, bouton « Accepter pour X F ».
/// Renvoie true si la course a été acceptée.
Future<bool?> showCourseSheet(
  BuildContext context,
  Map<String, dynamic> d,
  LatLng? me,
) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _CourseSheet(d, me),
  );
}

class _CourseSheet extends StatefulWidget {
  final Map<String, dynamic> d;
  final LatLng? me;
  const _CourseSheet(this.d, this.me);

  @override
  State<_CourseSheet> createState() => _CourseSheetState();
}

class _CourseSheetState extends State<_CourseSheet> {
  final _map = MapController();
  RouteInfo? _toPickup; // moi → A
  RouteInfo? _trip; // A → B
  bool _accepting = false;
  bool _ready = false;

  LatLng? get _a => pointOf(widget.d, 'pickup');
  LatLng? get _b => pointOf(widget.d, 'dropoff');

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final api = Api.instance;
    final a = _a, b = _b, me = widget.me;
    try {
      final results = await Future.wait([
        if (a != null && b != null) api.route(a, b),
        if (me != null && a != null) api.route(me, a),
      ]);
      if (!mounted) return;
      setState(() {
        if (a != null && b != null) _trip = results.first;
        if (me != null && a != null) _toPickup = results.last;
      });
      _fit();
    } catch (_) {}
  }

  void _fit() {
    if (!_ready) return;
    fitPoints(_map, [
      widget.me,
      _a,
      _b,
      ...?_trip?.points,
      ...?_toPickup?.points,
    ], padding: const EdgeInsets.fromLTRB(40, 70, 40, 30));
  }

  Future<void> _accept() async {
    setState(() => _accepting = true);
    try {
      await Api.instance.accept(widget.d['id']);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
      Navigator.pop(context, false);
    }
  }

  LatLng _mid(List<LatLng> pts) => pts[pts.length ~/ 2];

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final a = _a, b = _b;
    final cod = (d['codAmount'] ?? 0) as num;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.zero,
        children: [
          // ----- Carte -----
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SizedBox(
              height: 300,
              child: Stack(
                children: [
                  LetoMap(
                    controller: _map,
                    center: a ?? abidjan,
                    onReady: () {
                      _ready = true;
                      _fit();
                    },
                    layers: [
                      if (_toPickup != null)
                        routeLayer(
                          _toPickup!.points,
                          color: const Color(0xFF3D5AFE),
                        ),
                      if (_trip != null)
                        routeLayer(
                          _trip!.points,
                          color: const Color(0xFF2E7D32),
                        ),
                      MarkerLayer(
                        markers: [
                          if (a != null) pointMarker(a),
                          if (b != null) pointMarker(b, dropoff: true),
                          if (widget.me != null) myMarker(widget.me!),
                          if (_toPickup != null &&
                              _toPickup!.points.length > 1 &&
                              _toPickup!.distanceKm > 0.05)
                            routeLabel(
                              _mid(_toPickup!.points),
                              '${_toPickup!.durationMin} min · ${km(_toPickup!.distanceKm)}',
                              const Color(0xFF3D5AFE),
                            ),
                          if (_trip != null && _trip!.points.length > 1)
                            routeLabel(
                              _mid(_trip!.points),
                              '${_trip!.durationMin} min · ${km(_trip!.distanceKm)}',
                              const Color(0xFF2E7D32),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const Positioned(
                    top: 14,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        'Commande de course',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(color: Colors.white, blurRadius: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ----- Détails -----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Avatar(d['client']?['name'] ?? '?', radius: 28),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 80,
                          child: Text(
                            d['client']?['name'] ?? '',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          timeAgo(d['createdAt']),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (d['distanceKm'] != null)
                            Text(
                              '~${km(d['distanceKm'])}',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          Text(
                            fcfa(d['price']),
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          PointLine(
                            title:
                                '${d['pickupAddress']} (${d['pickupCommune']})',
                            detail: d['pickupDetails'],
                          ),
                          PointLine(
                            dropoff: true,
                            title:
                                '${d['dropoffAddress']} (${d['dropoffCommune']})',
                            detail: d['dropoffDetails'],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Pill(
                      '${vehicleLabels[d['vehicleType']]} · ${speedLabels[d['speed']]}',
                      bg: const Color(0xFFEDEDED),
                      fg: letoDark,
                      icon: vehicleIcons[d['vehicleType']],
                    ),
                    PaymentBadge(d['paymentMethod']),
                    if (cod > 0) CodBadge(cod),
                  ],
                ),
                if (d['pickupPhotoUrl'] != null ||
                    d['dropoffPhotoUrl'] != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (d['pickupPhotoUrl'] != null) ...[
                        AddressPhoto(d['pickupPhotoUrl']),
                        const SizedBox(width: 8),
                      ],
                      if (d['dropoffPhotoUrl'] != null)
                        AddressPhoto(d['dropoffPhotoUrl']),
                    ],
                  ),
                ],
                if ((d['courierComment'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.chat_bubble_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(d['courierComment'])),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(58),
                  ),
                  onPressed: _accepting ? null : _accept,
                  child: Text(
                    _accepting
                        ? 'Acceptation…'
                        : 'Accepter pour ${fcfa(d['price'])}',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF1F1EF),
                    foregroundColor: letoDark,
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Fermer'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
