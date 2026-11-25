import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import 'widgets.dart';

/// Fiche d'une course disponible : carte (moi → départ en bleu, tournée en vert),
/// arrêts, « Accepter pour X F » ou « Proposez votre prix ».
/// Renvoie 'accepted', 'offered' ou null.
Future<String?> showCourseSheet(
  BuildContext context,
  Map<String, dynamic> d,
  LatLng? me, {
  Map<String, dynamic>? myOffer,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Palette.of(context).background,
    shape: const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CourseSheet(d, me, myOffer),
  );
}

class _CourseSheet extends StatefulWidget {
  final Map<String, dynamic> d;
  final LatLng? me;
  final Map<String, dynamic>? myOffer;
  const _CourseSheet(this.d, this.me, this.myOffer);

  @override
  State<_CourseSheet> createState() => _CourseSheetState();
}

class _CourseSheetState extends State<_CourseSheet> {
  final _map = MapController();
  RouteInfo? _toPickup;
  RouteInfo? _trip;
  bool _busy = false;
  bool _ready = false;

  List<Map<String, dynamic>> get _stops =>
      (widget.d['stops'] as List).cast<Map<String, dynamic>>();
  LatLng get _a => pointOf(widget.d, 'pickup')!;
  List<LatLng> get _stopPoints => [
    for (final s in _stops)
      LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()),
  ];

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final api = Api.instance;
    try {
      final trip = await api.routeVia([_a, ..._stopPoints]);
      final toA = widget.me == null ? null : await api.route(widget.me!, _a);
      if (!mounted) return;
      setState(() {
        _trip = trip;
        _toPickup = toA;
      });
      _fit();
    } catch (_) {}
  }

  void _fit() {
    if (_ready) {
      fitPoints(_map, [
        widget.me,
        _a,
        ..._stopPoints,
        ...?_trip?.points,
      ], padding: const EdgeInsets.fromLTRB(36, 50, 36, 30));
    }
  }

  int _round50(num v) => ((v / 50).ceil() * 50).toInt();

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await Api.instance.accept(widget.d['id']);
      hapticSuccess();
      if (mounted) Navigator.pop(context, 'accepted');
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
      Navigator.pop(context);
    }
  }

  /// Course affectée par mon entreprise (prix fixé par elle, refus possible avec un motif)
  bool get _assigned =>
      widget.d['assignedDriverId'] != null &&
      widget.d['assignedDriverId'] == Api.instance.user?['id'];

  Future<void> _decline() async {
    final reason = await prompt(
      context,
      'Refuser la course',
      message:
          'Votre entreprise est prévenue et pourra l’affecter à un autre livreur.',
      placeholder: 'Motif (ex. : panne, trop loin)',
      ok: 'Refuser',
    );
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      await Api.instance.declineAssignment(
        widget.d['id'],
        reason: reason.isEmpty ? null : reason,
      );
      if (mounted) Navigator.pop(context, 'declined');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _propose(int price) async {
    setState(() => _busy = true);
    try {
      await Api.instance.proposePrice(widget.d['id'], price);
      hapticSuccess();
      if (mounted) Navigator.pop(context, 'offered');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _customPrice() async {
    final base = widget.d['price'] as int;
    final value = await prompt(
      context,
      'Votre prix',
      message:
          'Entre ${formatMoney(base + 50, widget.d['currency'])} et ${formatMoney(base * 2, widget.d['currency'])}',
      initial: '${_round50(base * 1.3)}',
      keyboard: TextInputType.number,
      ok: 'Proposer',
      large: true,
    );
    final price = int.tryParse((value ?? '').replaceAll(' ', ''));
    if (price != null) await _propose(price);
  }

  LatLng _mid(List<LatLng> pts) => pts[pts.length ~/ 2];

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = widget.d;
    final cod = _stops.fold<num>(0, (s, x) => s + (x['codAmount'] ?? 0));
    final n = _stops.length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.94,
      maxChildSize: 0.96,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.zero,
        children: [
          // ----- Carte -----
          ClipRSuperellipse(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SizedBox(
              // Carte plus grande : 42 % de l'écran (au moins 300 points)
              height: math.max(300, MediaQuery.sizeOf(context).height * 0.42),
              child: Stack(
                children: [
                  LetoMap(
                    controller: _map,
                    center: _a,
                    onReady: () {
                      _ready = true;
                      _fit();
                    },
                    layers: [
                      if (_toPickup != null)
                        routeLayer(_toPickup!.points, color: p.blue),
                      if (_trip != null)
                        routeLayer(_trip!.points, color: p.label),
                      MarkerLayer(
                        markers: [
                          pickupMarker(_a),
                          for (var i = 0; i < n; i++)
                            stopMarker(context, _stopPoints[i], i + 1),
                          if (widget.me != null) myMarker(widget.me!),
                          if (_toPickup != null &&
                              _toPickup!.points.length > 1 &&
                              _toPickup!.distanceKm > 0.05)
                            routeLabel(
                              _mid(_toPickup!.points),
                              '${_toPickup!.durationMin} min · ${km(_toPickup!.distanceKm)}',
                              p.blue,
                            ),
                          if (_trip != null && _trip!.points.length > 1)
                            routeLabel(
                              _mid(_trip!.points),
                              '${_trip!.durationMin} min · ${km(_trip!.distanceKm)}',
                              p.label,
                            ),
                        ],
                      ),
                    ],
                  ),
                  const Positioned(top: 8, left: 0, right: 0, child: Grabber()),
                ],
              ),
            ),
          ),
          // ----- Détails -----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              if (n > 1) 'Tournée · $n arrêts',
                              if (d['distanceKm'] != null) km(d['distanceKm']),
                            ].join(' · '),
                            style: TextStyles.subheadline.copyWith(
                              color: p.secondaryLabel,
                            ),
                          ),
                          if (_toPickup != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Récupération : ${km(_toPickup!.distanceKm)} · ~${_toPickup!.durationMin} min',
                                style: TextStyles.subheadline.copyWith(
                                  color: p.blue,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (_trip != null)
                            Text(
                              'Livraison : ${km(_trip!.distanceKm)} · ~${_trip!.durationMin} min',
                              style: TextStyles.subheadline.copyWith(
                                color: p.label,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            formatMoney(d['price'], d['currency']),
                            style: TextStyles.largeTitle.copyWith(
                              color: p.label,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      children: [
                        Avatar(d['client']?['name'] ?? '?', radius: 22),
                        const SizedBox(height: 4),
                        Text(
                          timeAgo(d['createdAt']),
                          style: TextStyles.caption.copyWith(
                            color: p.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Pill(
                      '${vehicleLabels[d['vehicleType']]} · ${speedLabels[d['speed']]}',
                      color: p.label,
                      icon: vehicleIcons[d['vehicleType']],
                    ),
                    const CashPill(),
                    if (cod > 0) CodBadge(cod, currency: d['currency']),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: p.card,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Column(
                    children: [
                      PointLine(
                        title: '${d['pickupAddress']} (${d['pickupCommune']})',
                        detail: d['pickupDetails'],
                      ),
                      for (final s in _stops)
                        PointLine(
                          marker: '${s['position'] + 1}',
                          title: '${s['address']} (${s['commune']})',
                          detail: [
                            s['details'],
                            if ((s['codAmount'] ?? 0) > 0)
                              'Encaisser ${formatMoney(s['codAmount'], d['currency'])}',
                          ].whereType<String>().join(' · '),
                        ),
                    ],
                  ),
                ),
                if ((d['courierComment'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        PhosphorIconsBold.chatText,
                        size: 18,
                        color: p.secondaryLabel,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          d['courierComment'],
                          style: TextStyles.subheadline.copyWith(
                            color: p.label,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                if (_assigned) ...[
                  const Pill(
                    'Affectée par votre entreprise',
                    color: accent,
                    icon: PhosphorIconsFill.buildings,
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                  ),
                  onPressed: _busy ? null : _accept,
                  child: Text(
                    'Accepter pour ${formatMoney(d['price'], d['currency'])}',
                  ),
                ),
                if (_assigned) ...[
                  const SizedBox(height: 10),
                  CupertinoButton(
                    onPressed: _busy ? null : _decline,
                    child: Text(
                      'Refuser',
                      style: TextStyles.body.copyWith(color: p.red),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (!_assigned) ...[
                  if (widget.myOffer != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Pill(
                        'Votre proposition : ${formatMoney(widget.myOffer!['price'], d['currency'])} · en attente du client',
                        color: accentDeep,
                        icon: PhosphorIconsBold.hourglassMedium,
                      ),
                    ),
                  Text(
                    'Proposez votre prix',
                    textAlign: TextAlign.center,
                    style: TextStyles.subheadline.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final f in [1.1, 1.2]) ...[
                        Expanded(
                          child: _PriceChip(
                            key: ValueKey('propose-$f'),
                            label: formatMoney(
                              _round50(d['price'] * f),
                              d['currency'],
                            ),
                            onTap: _busy
                                ? null
                                : () => _propose(_round50(d['price'] * f)),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: _PriceChip(
                          icon: PhosphorIconsBold.pencilSimple,
                          onTap: _busy ? null : _customPrice,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                CupertinoButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Fermer',
                    style: TextStyles.body.copyWith(color: p.secondaryLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bouton de prix proposé (+10 %, +20 %, personnalisé)
class _PriceChip extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _PriceChip({super.key, this.label, this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              hapticTap();
              onTap!();
            },
      child: Container(
        height: 54,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: icon != null
            ? Icon(icon, color: p.label)
            : Text(label!, style: TextStyles.headline.copyWith(color: p.label)),
      ),
    );
  }
}
