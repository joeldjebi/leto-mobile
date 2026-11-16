import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import '../realtime.dart';
import 'share_codes.dart';
import 'widgets.dart';

/// Suivi d'une course / tournée côté expéditeur, en temps réel.
class TrackingScreen extends StatefulWidget {
  final String id;
  const TrackingScreen(this.id, {super.key});
  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  final api = Api.instance;
  final _map = MapController();
  Map<String, dynamic>? _d;
  RouteInfo? _route;
  Timer? _timer;
  Timer? _ticker;
  bool _mapReady = false;
  LatLng? _driverPos;
  bool _driverFitted = false;
  void Function()? _unsubscribe;
  List<Map<String, dynamic>> _offers = [];

  List<Map<String, dynamic>> get _stops =>
      ((_d?['stops'] as List?) ?? []).cast<Map<String, dynamic>>();
  bool get _finished => ['DELIVERED', 'CANCELLED'].contains(_d?['status']);
  bool _active(Map d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']);

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_finished) _load();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_offers.isEmpty || !mounted) return;
      setState(() => _offers.removeWhere((o) => _secondsLeft(o) <= 0));
    });
    final s = Realtime.instance.socket;
    s.on('driver:location', _onDriverLocation);
    s.on('delivery:updated', _onDeliveryUpdated);
    s.on('delivery:offers', _onOffers);
    s.on('stop:arrived', _onStopArrived);
    s.on('stop:failed', _onStopFailed);
    s.on('stop:cancel-request', _onCancelRequest);
    s.on('stop:cancelled', _onStopCancelled);
    s.on('delivery:return', _onReturn);
    _unsubscribe = Realtime.instance.onConnected(
      () => s.emit('delivery:watch', widget.id),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker?.cancel();
    final s = Realtime.instance.socket;
    s.off('driver:location', _onDriverLocation);
    s.off('delivery:updated', _onDeliveryUpdated);
    s.off('delivery:offers', _onOffers);
    s.off('stop:arrived', _onStopArrived);
    s.off('stop:failed', _onStopFailed);
    s.off('stop:cancel-request', _onCancelRequest);
    s.off('stop:cancelled', _onStopCancelled);
    s.off('delivery:return', _onReturn);
    s.emit('delivery:unwatch', widget.id);
    _unsubscribe?.call();
    super.dispose();
  }

  // ---------- Temps réel ----------

  void _onDriverLocation(dynamic e) {
    if (!mounted || e is! Map || e['deliveryId'] != widget.id) return;
    setState(
      () => _driverPos = LatLng(
        (e['lat'] as num).toDouble(),
        (e['lng'] as num).toDouble(),
      ),
    );
    _fitDriver();
  }

  void _onDeliveryUpdated(dynamic e) {
    if (e is Map && e['id'] == widget.id) _load();
  }

  void _onOffers(dynamic e) {
    if (e is Map && e['deliveryId'] == widget.id) _loadOffers();
  }

  void _onStopArrived(dynamic e) {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    showInfo(context, 'Le livreur est arrivé chez ${e['recipientName']}');
    _load();
  }

  void _onStopFailed(dynamic e) {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    showError(
      context,
      'Livraison impossible chez ${e['recipientName']} : voir la photo du livreur',
    );
    _load();
  }

  /// Le livreur indique que le destinataire annule : l'expéditeur confirme ou refuse
  Future<void> _onCancelRequest(dynamic e) async {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    await _load();
    final stop = _stops.where((s) => s['id'] == e['stopId']).firstOrNull;
    if (stop != null && mounted) _answerCancel(stop);
  }

  void _onStopCancelled(dynamic e) {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    showInfo(context, 'Livraison de ${e['recipientName']} annulée');
    _load();
  }

  void _onReturn(dynamic e) {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    showInfo(
      context,
      'Le livreur vous rapporte ${e['parcels']} colis : donnez-lui votre code de retour',
    );
    _load();
  }

  // ---------- Données ----------

  Future<void> _load() async {
    try {
      final d = await api.getDelivery(widget.id);
      final first = _d == null;
      if (!mounted) return;
      setState(() {
        _d = d;
        final driver = d['driver'];
        if (_driverPos == null &&
            driver != null &&
            driver['lastLat'] != null &&
            _active(d)) {
          _driverPos = LatLng(
            (driver['lastLat'] as num).toDouble(),
            (driver['lastLng'] as num).toDouble(),
          );
        }
      });
      if (first) {
        _fit();
        _loadRoute(d);
      }
      _fitDriver();
      _loadOffers();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _loadRoute(Map<String, dynamic> d) async {
    final pts = [
      pointOf(d, 'pickup')!,
      for (final s in _stops)
        LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()),
    ];
    try {
      final r = await api.routeVia(pts);
      if (!mounted) return;
      setState(() => _route = r);
      if (_mapReady && !_driverFitted) {
        fitPoints(_map, [
          ...pts,
          ...r.points,
        ], padding: const EdgeInsets.fromLTRB(40, 90, 40, 30));
      }
    } catch (_) {}
  }

  List<LatLng> get _allPoints => [
    if (_d != null) pointOf(_d!, 'pickup')!,
    for (final s in _stops)
      LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()),
  ];

  void _fit() {
    if (_mapReady && _d != null) {
      fitPoints(_map, [
        ..._allPoints,
        ...?_route?.points,
      ], padding: const EdgeInsets.fromLTRB(40, 90, 40, 30));
    }
  }

  /// Au premier point GPS du livreur : cadre le livreur et sa prochaine étape
  void _fitDriver() {
    if (_driverFitted || !_mapReady || _d == null || _driverPos == null) return;
    final next = _d!['status'] == 'PICKED_UP'
        ? _stops
              .where((s) => s['status'] == 'PENDING')
              .map(
                (s) => LatLng(
                  (s['lat'] as num).toDouble(),
                  (s['lng'] as num).toDouble(),
                ),
              )
              .firstOrNull
        : pointOf(_d!, 'pickup');
    fitPoints(_map, [_driverPos, next]);
    _driverFitted = true;
  }

  // ---------- Proposez votre prix ----------

  int _secondsLeft(Map o) =>
      DateTime.parse(o['expiresAt']).difference(DateTime.now()).inSeconds;

  Future<void> _loadOffers() async {
    if (_d?['status'] != 'PENDING') {
      if (_offers.isNotEmpty) setState(() => _offers = []);
      return;
    }
    try {
      final list = await api.offersFor(widget.id);
      if (mounted) setState(() => _offers = list.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _acceptOffer(Map o) async {
    try {
      await api.acceptOffer(o['id']);
      hapticSuccess();
      if (mounted) {
        showInfo(
          context,
          '${o['driver']['name']} arrive pour ${fcfa(o['price'])}',
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
      _loadOffers();
    }
  }

  Future<void> _declineOffer(Map o) async {
    setState(() => _offers.remove(o));
    try {
      await api.declineOffer(o['id']);
    } catch (_) {}
  }

  // ---------- Actions ----------

  /// Annuler toute la course (en attente, ou livreur en route : frais éventuels annoncés)
  Future<void> _cancel() async {
    var fee = 0;
    try {
      final preview = await api.cancelPreview(widget.id);
      if (preview['allowed'] != true) {
        if (mounted)
          showError(context, preview['reason'] ?? 'Annulation impossible');
        return;
      }
      fee = (preview['fee'] ?? 0) as int;
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final enRoute = _d?['status'] == 'ACCEPTED';
    if (!await confirm(
      context,
      'Annuler la livraison ?',
      message: fee > 0
          ? 'Le livreur est déjà en route : des frais de déplacement de ${fcfa(fee)} seront dus à son entreprise.'
          : enRoute
          ? 'Le livreur sera prévenu immédiatement.'
          : null,
      ok: fee > 0 ? 'Annuler et payer ${fcfa(fee)}' : 'Oui, annuler',
      destructive: true,
    )) {
      return;
    }
    try {
      await api.cancel(widget.id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Retirer un arrêt (un client de la boutique annule)
  Future<void> _cancelStop(Map<String, dynamic> stop) async {
    final pickedUp = _d?['status'] == 'PICKED_UP';
    final reason = await prompt(
      context,
      'Annuler la livraison de ${stop['recipientName']} ?',
      message: pickedUp
          ? 'Le colis est déjà chez le livreur : le prix reste le même et le colis vous sera rapporté.'
          : 'Le prix et l’itinéraire seront recalculés, le livreur est prévenu.',
      placeholder: 'Motif (facultatif)',
      ok: 'Annuler l’arrêt',
    );
    if (reason == null) return;
    try {
      await api.cancelStop(
        widget.id,
        stop['id'],
        reason: reason.isEmpty ? null : reason,
      );
      hapticSuccess();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Réponse à une annulation signalée par le livreur
  Future<void> _answerCancel(Map<String, dynamic> stop) async {
    final choice = await showActions<bool>(
      context,
      title: 'Le livreur indique que ${stop['recipientName']} annule',
      message: [
        if ((stop['cancelRequestNote'] ?? '').toString().isNotEmpty)
          '« ${stop['cancelRequestNote']} »',
        'Sans réponse, l’annulation sera acceptée automatiquement.',
      ].join('\n'),
      actions: [
        ('Confirmer l’annulation', true, true),
        ('Maintenir la livraison', false, false),
      ],
    );
    if (choice == null) return;
    try {
      await api.answerCancelRequest(widget.id, stop['id'], choice);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _dispute(Map<String, dynamic> stop) async {
    final note = await prompt(
      context,
      'Contester l’absence',
      message:
          'Expliquez pourquoi (ex. : la cliente était chez elle). L’entreprise de livraison examinera les preuves.',
      placeholder: 'Votre explication',
      ok: 'Contester',
    );
    if (note == null) return;
    try {
      await api.disputeStop(widget.id, stop['id'], note.isEmpty ? null : note);
      if (mounted) {
        showInfo(context, 'Contestation envoyée à l’entreprise de livraison');
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = _d;
    return Scaffold(
      backgroundColor: p.background,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                LetoMap(
                  controller: _map,
                  center: d == null ? abidjan : pointOf(d, 'pickup')!,
                  onReady: () {
                    _mapReady = true;
                    _fit();
                  },
                  layers: [
                    if (_route != null) routeLayer(_route!.points),
                    MarkerLayer(
                      markers: [
                        if (d != null) pickupMarker(pointOf(d, 'pickup')!),
                        for (final s in _stops)
                          stopMarker(
                            context,
                            LatLng(
                              (s['lat'] as num).toDouble(),
                              (s['lng'] as num).toDouble(),
                            ),
                            s['position'] + 1,
                            status: s['status'],
                          ),
                      ],
                    ),
                    // Livreur en temps réel : glisse en douceur d'une position à la suivante
                    if (_driverPos != null && d != null && _active(d))
                      TweenAnimationBuilder<LatLng>(
                        tween: _LatLngTween(end: _driverPos),
                        duration: const Duration(milliseconds: 1200),
                        curve: Curves.easeInOut,
                        builder: (_, pos, _) =>
                            MarkerLayer(markers: [driverMarker(pos)]),
                      ),
                  ],
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: MapButton(
                      CupertinoIcons.chevron_back,
                      onTap: () => Navigator.pop(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: SingleChildScrollView(
              child: GlassPanel(
                children: d == null
                    ? [
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: CupertinoActivityIndicator(),
                        ),
                      ]
                    : _panel(d, p),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _panel(Map<String, dynamic> d, Palette p) {
    final status = d['status'] as String;
    final n = _stops.length;
    final delivered = _stops.where((s) => s['status'] == 'DELIVERED').length;
    final failed = _stops.where((s) => s['status'] == 'FAILED').length;
    final title = switch (status) {
      'PENDING' => 'Recherche d’un livreur…',
      'ACCEPTED' => 'Le livreur arrive au départ',
      'PICKED_UP' =>
        n > 1
            ? 'Tournée en cours · $delivered/$n livrés'
            : 'Votre colis est en route',
      'DELIVERED' =>
        failed == 0
            ? 'Livraison terminée'
            : 'Terminée · $delivered livré(s), $failed échec(s)',
      _ => 'Livraison annulée',
    };

    return [
      Text(title, style: TextStyles.title2.copyWith(color: p.label)),
      const SizedBox(height: 10),
      if (status == 'PENDING') ...[
        const LinearProgressIndicator(
          minHeight: 3,
          borderRadius: BorderRadius.all(Radius.circular(2)),
          color: accent,
        ),
        const SizedBox(height: 8),
        Text(
          'Votre demande est visible par les livreurs à proximité.',
          style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
        ),
        const SizedBox(height: 12),
      ],
      if (status == 'PENDING' && _offers.isNotEmpty) ...[
        Text(
          'Propositions des livreurs',
          style: TextStyles.headline.copyWith(color: p.label),
        ),
        const SizedBox(height: 8),
        for (final o in _offers)
          _OfferTile(
            offer: o,
            original: d['price'],
            secondsLeft: _secondsLeft(o),
            onAccept: () => _acceptOffer(o),
            onDecline: () => _declineOffer(o),
          ),
        const SizedBox(height: 6),
      ],
      if (status != 'CANCELLED') StatusSteps(status),
      const SizedBox(height: 14),
      if (status == 'PENDING' &&
          d['targetCompanyId'] != null &&
          d['source'] == 'CLIENT') ...[
        Builder(
          builder: (_) {
            final waited = DateTime.now()
                .difference(DateTime.parse(d['createdAt']))
                .inMinutes;
            return waited >= 5
                ? _notice(
                    p,
                    icon: CupertinoIcons.clock_fill,
                    color: p.yellow,
                    title: 'Pas encore de réponse de l’entreprise choisie',
                    text:
                        'Ouvrir la course à tous les livreurs disponibles (même prix) ?',
                    onTap: _openToAll,
                  )
                : _notice(
                    p,
                    icon: CupertinoIcons.building_2_fill,
                    color: accent,
                    title: 'Envoyée à votre entreprise de livraison',
                    text:
                        'Seuls ses livreurs la voient. Sans réponse dans 5 min, vous pourrez l’ouvrir à tous.',
                  );
          },
        ),
        const SizedBox(height: 12),
      ],
      if (trackingUrl(d) != null && !_finished) ...[
        Builder(
          builder: (ctx) => Pressable(
            onTap: () => _shareTracking(ctx, d),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: ShapeDecoration(
                color: p.accentSoft,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.link, color: accent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Partager le suivi en direct',
                      style: TextStyles.subheadline.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(CupertinoIcons.share, color: accent, size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      // Colis non livrés rapportés par le livreur : code de retour
      if (d['returnRequired'] == true && d['returnedAt'] == null) ...[
        _notice(
          p,
          icon: CupertinoIcons.arrow_uturn_left_circle_fill,
          color: accent,
          title: 'Colis en retour',
          text:
              'Le livreur vous rapporte les colis non livrés. Donnez-lui ce code en les récupérant.',
          trailing: Text(
            d['returnCode'] ?? '',
            style: TextStyles.title2.copyWith(color: p.label, letterSpacing: 4),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (d['returnedAt'] != null) ...[
        _notice(
          p,
          icon: CupertinoIcons.checkmark_seal_fill,
          color: p.green,
          title: 'Colis non livrés récupérés',
          text: 'Retour confirmé avec votre code.',
        ),
        const SizedBox(height: 12),
      ],
      for (final s in _stops.where(
        (s) => s['status'] == 'PENDING' && s['cancelRequestedAt'] != null,
      )) ...[
        _notice(
          p,
          icon: CupertinoIcons.exclamationmark_circle_fill,
          color: p.yellow,
          title: '${s['recipientName']} annule ?',
          text:
              'Le livreur signale une annulation. Confirmez ou maintenez la livraison.',
          onTap: () => _answerCancel(s),
        ),
        const SizedBox(height: 12),
      ],
      if (status == 'CANCELLED' && (d['cancellationFee'] ?? 0) > 0) ...[
        _notice(
          p,
          icon: CupertinoIcons.money_dollar_circle_fill,
          color: p.red,
          title: 'Frais de déplacement : ${fcfa(d['cancellationFee'])}',
          text: d['cancellationFeeSettledAt'] != null
              ? 'Réglés auprès de l’entreprise de livraison.'
              : 'Le livreur était en route. À régler auprès de l’entreprise de livraison.',
        ),
        const SizedBox(height: 12),
      ],
      if (d['driver'] != null) _driverCard(d, p),
      const SizedBox(height: 12),
      // ----- Destinataires -----
      Row(
        children: [
          Text(
            n > 1 ? 'Destinataires' : 'Destinataire',
            style: TextStyles.headline.copyWith(color: p.label),
          ),
          const Spacer(),
          if (!_finished && _stops.any((s) => s['status'] == 'PENDING'))
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () => showShareCodes(context, d),
              child: Text(
                'Partager les codes',
                style: TextStyles.subheadline.copyWith(color: accent),
              ),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Container(
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Column(
          children: [
            for (var i = 0; i < n; i++) ...[
              _StopTile(
                d: d,
                stop: _stops[i],
                onDispute: () => _dispute(_stops[i]),
                onCancel: _active(d) || status == 'PENDING'
                    ? () => _cancelStop(_stops[i])
                    : null,
              ),
              if (i < n - 1)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: 52,
                  color: p.separator,
                ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Text(
            d['distanceKm'] != null
                ? '${km(d['distanceKm'])} · ${vehicleLabels[d['vehicleType']]} · ${speedLabels[d['speed']]}'
                : '',
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
          const Spacer(),
          Text(
            'Espèces  ',
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
          Text(
            fcfa(d['price']),
            style: TextStyles.title3.copyWith(color: p.label),
          ),
        ],
      ),
      if (status == 'PENDING' || status == 'ACCEPTED') ...[
        const SizedBox(height: 12),
        CupertinoButton(
          onPressed: _cancel,
          child: Text(
            status == 'PENDING' ? 'Annuler la demande' : 'Annuler la livraison',
            style: TextStyles.body.copyWith(color: p.red),
          ),
        ),
      ],
    ];
  }

  /// Encadré d'information (retour, annulation en attente, frais)
  Widget _notice(
    Palette p, {
    required IconData icon,
    required Color color,
    required String title,
    required String text,
    Widget? trailing,
    VoidCallback? onTap,
  }) => Pressable(
    onTap: onTap,
    pressedScale: 0.98,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                Text(
                  text,
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
          if (onTap != null)
            Icon(
              CupertinoIcons.chevron_right,
              color: p.tertiaryLabel,
              size: 16,
            ),
        ],
      ),
    ),
  );

  /// Délai d'arrivée estimé du livreur (départ, puis prochain arrêt) : 20 km/h en ville
  int? _etaMin(Map<String, dynamic> d) {
    if (_driverPos == null || !_active(d)) return null;
    final LatLng? target;
    if (d['status'] == 'ACCEPTED') {
      target = pointOf(d, 'pickup');
    } else {
      final next = _stops.where((s) => s['status'] == 'PENDING').firstOrNull;
      target = next == null
          ? null
          : LatLng(
              (next['lat'] as num).toDouble(),
              (next['lng'] as num).toDouble(),
            );
    }
    if (target == null) return null;
    return (distanceKm(_driverPos!, target) * 1.35 / 20 * 60).ceil().clamp(
      1,
      999,
    );
  }

  /// Partager le lien de suivi (client, destinataires…)
  Future<void> _shareTracking(BuildContext ctx, Map<String, dynamic> d) async {
    final url = trackingUrl(d);
    if (url == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: 'Suivez ma livraison LETO en direct : $url',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  /// Course adressée à une entreprise restée sans réponse : l'ouvrir à toutes
  Future<void> _openToAll() async {
    try {
      await api.openToAll(widget.id);
      hapticSuccess();
      if (mounted)
        showInfo(context, 'Course ouverte à tous les livreurs disponibles');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _driverCard(Map<String, dynamic> d, Palette p) {
    final driver = d['driver'];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        children: [
          Avatar(driver['name'], radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  driver['name'],
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                Text(
                  [
                    if (_etaMin(d) != null)
                      d['status'] == 'ACCEPTED'
                          ? 'au départ dans ~${_etaMin(d)} min'
                          : 'chez le destinataire dans ~${_etaMin(d)} min',
                    d['company']?['name'] ?? '',
                    if (_active(d) && _driverPos != null && _etaMin(d) == null)
                      'position en direct',
                  ].where((x) => x.isNotEmpty).join(' · '),
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ],
            ),
          ),
          Icon(CupertinoIcons.phone_fill, size: 16, color: p.green),
          const SizedBox(width: 4),
          SelectableText(
            driver['phone'],
            style: TextStyles.subheadline.copyWith(
              color: p.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Un destinataire : statut, code à partager, preuves en cas d'échec
class _StopTile extends StatelessWidget {
  final Map<String, dynamic> d;
  final Map<String, dynamic> stop;
  final VoidCallback onDispute;
  final VoidCallback? onCancel;
  const _StopTile({
    required this.d,
    required this.stop,
    required this.onDispute,
    this.onCancel,
  });

  String _time(String iso) {
    final t = DateTime.parse(iso).toLocal();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = stop['status'] as String;
    final cod = (stop['codAmount'] ?? 0) as num;
    final subtitle = switch (status) {
      'DELIVERED' => 'Livré à ${_time(stop['deliveredAt'])}',
      'FAILED' =>
        '${failureLabels[stop['failureReason']]} · ${_time(stop['failedAt'])}',
      'CANCELLED' =>
        'Annulé · ${_time(stop['cancelledAt'])}${stop['cancelReason'] != null ? ' · ${stop['cancelReason']}' : ''}',
      _ =>
        stop['arrivedAt'] != null
            ? 'Le livreur est sur place'
            : stop['address'],
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: stopColor(context, status),
                  shape: BoxShape.circle,
                ),
                child: status == 'DELIVERED'
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: Colors.white,
                        size: 16,
                      )
                    : status == 'CANCELLED'
                    ? const Icon(
                        CupertinoIcons.minus,
                        color: Colors.white,
                        size: 14,
                      )
                    : status == 'FAILED'
                    ? const Icon(
                        CupertinoIcons.xmark,
                        color: Colors.white,
                        size: 14,
                      )
                    : Text(
                        '${stop['position'] + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stop['recipientName'],
                      style: TextStyles.subheadline.copyWith(
                        color: p.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyles.footnote.copyWith(
                        color: stop['arrivedAt'] != null && status == 'PENDING'
                            ? p.green
                            : p.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
              if (status == 'PENDING') ...[
                Text(
                  stop['confirmationCode'] ?? '',
                  style: TextStyles.headline.copyWith(
                    color: p.label,
                    letterSpacing: 3,
                  ),
                ),
                Builder(
                  builder: (ctx) => CupertinoButton(
                    padding: const EdgeInsets.only(left: 8),
                    minimumSize: Size.zero,
                    onPressed: () => shareToWhatsApp(ctx, d, stop),
                    child: Icon(CupertinoIcons.share, size: 20, color: p.blue),
                  ),
                ),
                if (onCancel != null)
                  CupertinoButton(
                    padding: const EdgeInsets.only(left: 10),
                    minimumSize: Size.zero,
                    onPressed: onCancel,
                    child: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      size: 22,
                      color: p.tertiaryLabel,
                    ),
                  ),
              ],
            ],
          ),
          if (cod > 0 && status != 'FAILED')
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Pill(
                stop['codRemittedAt'] != null
                    ? '${fcfa(cod)} reversé'
                    : status == 'DELIVERED'
                    ? '${fcfa(cod)} encaissé'
                    : 'Encaisser ${fcfa(cod)}',
                color: stop['codRemittedAt'] != null ? p.green : accentDeep,
                icon: CupertinoIcons.creditcard,
              ),
            ),
          // ----- Preuves d'échec + contestation -----
          if (status == 'FAILED')
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stop['failurePhotoUrl'] != null) ...[
                    AddressPhoto(stop['failurePhotoUrl'], size: 56),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (stop['failureNote'] != null)
                          Text(
                            '« ${stop['failureNote']} »',
                            style: TextStyles.footnote.copyWith(color: p.label),
                          ),
                        if (stop['arrivedAt'] != null &&
                            stop['failedAt'] != null)
                          Text(
                            'Sur place ${_time(stop['arrivedAt'])} → ${_time(stop['failedAt'])} (position GPS vérifiée)',
                            style: TextStyles.caption.copyWith(
                              color: p.secondaryLabel,
                            ),
                          ),
                        const SizedBox(height: 4),
                        stop['disputedAt'] != null
                            ? Pill(
                                'Contestation envoyée',
                                color: p.blue,
                                icon: CupertinoIcons.flag,
                              )
                            : CupertinoButton(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                onPressed: onDispute,
                                child: Text(
                                  'Contester',
                                  style: TextStyles.subheadline.copyWith(
                                    color: p.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ],
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

/// Proposition de prix d'un livreur (accepter / refuser)
class _OfferTile extends StatelessWidget {
  final Map<String, dynamic> offer;
  final num original;
  final int secondsLeft;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _OfferTile({
    required this.offer,
    required this.original,
    required this.secondsLeft,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final mm = (secondsLeft ~/ 60).toString();
    final ss = (secondsLeft % 60).toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: accent.withValues(alpha: 0.5)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(offer['driver']['name'], radius: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer['driver']['name'],
                      style: TextStyles.headline.copyWith(color: p.label),
                    ),
                    Text(
                      [
                        if (offer['company'] != null) offer['company']['name'],
                        if (offer['etaMin'] != null)
                          'arrive en ~${offer['etaMin']} min',
                      ].join(' · '),
                      style: TextStyles.footnote.copyWith(
                        color: p.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fcfa(offer['price']),
                    style: TextStyles.title3.copyWith(
                      color: p.label,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '+${fcfa(offer['price'] - original)}',
                    style: TextStyles.caption.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '$mm:$ss',
                style: TextStyles.footnote.copyWith(
                  color: p.secondaryLabel,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              CupertinoButton(
                onPressed: onDecline,
                child: Text(
                  'Refuser',
                  style: TextStyles.body.copyWith(color: p.secondaryLabel),
                ),
              ),
              SizedBox(
                width: 130,
                child: FilledButton(
                  onPressed: onAccept,
                  child: const Text('Accepter'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Interpolation entre deux positions (animation du livreur)
class _LatLngTween extends Tween<LatLng> {
  _LatLngTween({super.end});

  @override
  LatLng lerp(double t) {
    final a = begin ?? end!, b = end!;
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }
}
