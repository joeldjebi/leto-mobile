import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../live_activity.dart';
import '../main.dart';
import '../realtime.dart';
import 'cancel_reasons.dart';
import 'searching_header.dart';
import 'share_codes.dart';
import 'tracking_parts.dart';
import '../models.dart';
import 'widgets.dart';

/// Suivi d'une course / tournée côté expéditeur, en temps réel.
class TrackingScreen extends StatefulWidget {
  final String id;
  const TrackingScreen(this.id, {super.key});
  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with TickerProviderStateMixin {
  // Recherche d'un livreur : ondes radar, livreurs autour du départ, délai d'expiration
  late final AnimationController _radar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();
  List<NearbyDriver> _nearby = [];
  int _expiryMin = 0;
  Timer? _nearbyTimer;

  final api = Api.instance;
  final _map = MapController();
  Map<String, dynamic>? _d;
  RouteInfo? _route;
  Timer? _timer;
  Timer? _ticker;
  bool _mapReady = false;
  LatLng? _driverPos;

  // Livreur en direct : glissement continu entre deux points GPS, cap, caméra qui suit
  late final AnimationController _move = AnimationController(vsync: this)
    ..addListener(_onMoveTick);
  final _livePos = ValueNotifier<LatLng?>(null);
  LatLng? _moveFrom;
  DateTime? _lastFixAt;
  double _headingTurns =
      0; // cumulé (tours) pour tourner toujours par le plus court
  bool _hasHeading = false;
  bool _follow = false;

  // Panneau déroulant : moitié de l'écran au départ, agrandissable presque en plein écran
  static const _sheetMid = 0.5, _sheetMax = 0.94, _sheetMin = 0.24;
  final _sheet = DraggableScrollableController();
  final _sheetExtent = ValueNotifier<double>(_sheetMid);

  // « Montrer au livreur où je me trouve » : partage de ma position tant que l'écran est ouvert
  bool _sharing = false;
  LatLng? _myPos;
  StreamSubscription<Position>? _shareGps;
  Timer? _shareTimer;
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
    // Animations créées tout de suite (et non à la première utilisation, qui pouvait tomber dans dispose)
    _radar;
    _move;
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_finished) _load();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_offers.isEmpty) return;
      setState(() => _offers.removeWhere((o) => _secondsLeft(o) <= 0));
    });
    _loadExpiry();
    _nearbyTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _loadNearby(),
    );
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
    _nearbyTimer?.cancel();
    _stopSharing(notify: true, disposing: true);
    _radar.dispose();
    _move.dispose();
    _sheet.dispose();
    _sheetExtent.dispose();
    _livePos.dispose();
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
    final next = LatLng(
      (e['lat'] as num).toDouble(),
      (e['lng'] as num).toDouble(),
    );
    _animateDriver(next, heading: (e['heading'] as num?)?.toDouble());
    setState(() => _driverPos = next);
    _fitDriver();
    // Heure d'arrivée à jour dans la Live Activity (mise à jour seulement si elle change)
    final d = _d;
    if (d != null) {
      DeliveryLive.instance.sync(d, driver: false, etaMin: _etaMin(d));
    }
  }

  /// Fait glisser le marqueur du point affiché vers le nouveau point, en une durée égale à
  /// l'intervalle entre deux positions : le livreur avance sans à-coups ni arrêts.
  void _animateDriver(LatLng next, {double? heading}) {
    final now = DateTime.now();
    final shown = _livePos.value;
    final gap = _lastFixAt == null
        ? 1000
        : now.difference(_lastFixAt!).inMilliseconds;
    _lastFixAt = now;
    final jump = shown == null ? 0.0 : distanceKm(shown, next) * 1000;
    // Premier point, ou saut irréaliste (reprise après coupure) : on place directement
    if (shown == null || jump > 400) {
      _move.stop();
      _livePos.value = next;
      _moveFrom = next;
      _driverPos = next;
      _followTo(next);
      return;
    }
    // Cap : celui du GPS en mouvement, sinon la direction du déplacement
    final bearing =
        heading ?? (jump > 4 ? _bearing(_driverPos ?? shown, next) : null);
    if (bearing != null) _turnTo(bearing);
    _moveFrom = shown;
    _move.duration = Duration(
      milliseconds: (gap * 1.1).clamp(500, 4000).round(),
    );
    _move.forward(from: 0);
  }

  void _onMoveTick() {
    final a = _moveFrom, b = _driverPos;
    if (a == null || b == null) return;
    final t = _move.value;
    final p = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    _livePos.value = p;
    _followTo(p);
  }

  void _followTo(LatLng p) {
    if (_follow && _mapReady) {
      _map.move(
        p,
        math.max(_map.camera.zoom, 16),
        offset: _visibleCenterOffset,
      );
    }
  }

  void _turnTo(double deg) {
    final current = _headingTurns % 1;
    var delta = deg / 360 - current;
    if (delta > 0.5) delta -= 1;
    if (delta < -0.5) delta += 1;
    _headingTurns += delta;
    _hasHeading = true;
  }

  static double _bearing(LatLng a, LatLng b) {
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final dl = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dl) * math.cos(la2);
    final x =
        math.cos(la1) * math.sin(la2) -
        math.sin(la1) * math.cos(la2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  Future<void> _startSharing() async {
    final first = await myPosition();
    if (!mounted) return;
    if (first == null) {
      showError(
        context,
        'Activez la localisation pour montrer votre position au livreur.',
      );
      return;
    }
    setState(() => _sharing = true);
    _sendMyPos(first);
    if (devPosition == null) {
      _shareGps =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((p) {
            if (p.accuracy <= 80) _sendMyPos(LatLng(p.latitude, p.longitude));
          }, onError: (_) {});
    }
    // Même immobile, la position reste « fraîche » côté livreur
    _shareTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_myPos != null) _sendMyPos(_myPos!);
    });
  }

  void _sendMyPos(LatLng p) {
    if (mounted) setState(() => _myPos = p);
    Realtime.instance.socket.emit('client:location', {
      'deliveryId': widget.id,
      'lat': p.latitude,
      'lng': p.longitude,
    });
  }

  void _stopSharing({bool notify = false, bool disposing = false}) {
    _shareGps?.cancel();
    _shareGps = null;
    _shareTimer?.cancel();
    _shareTimer = null;
    if (!_sharing) return;
    _sharing = false;
    if (notify) {
      Realtime.instance.socket.emit('client:location:stop', {
        'deliveryId': widget.id,
      });
    }
    if (mounted && !disposing) setState(() {});
  }

  void _toggleFollow() {
    final pos = _livePos.value;
    if (pos == null) return;
    hapticTap();
    setState(() => _follow = !_follow);
    if (_follow) {
      _map.move(
        pos,
        math.max(_map.camera.zoom, 16),
        offset: _visibleCenterOffset,
      );
    } else {
      _fitDriverAndNext();
    }
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
          _livePos.value = _driverPos;
          _moveFrom = _driverPos;
        }
      });
      // Course terminée ou annulée : le partage de position s'arrête (le serveur le retire aussi)
      if (_sharing && !_active(d)) _stopSharing();
      if (first) {
        _fit();
        _loadRoute(d);
      }
      _fitDriver();
      _loadOffers();
      if (first) _loadNearby();
      DeliveryLive.instance.sync(d, driver: false, etaMin: _etaMin(d));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Livreurs disponibles autour du départ (ceux qui peuvent recevoir la demande)
  Future<void> _loadNearby() async {
    final d = _d;
    if (d == null || d['status'] != 'PENDING') {
      if (_nearby.isNotEmpty && mounted) setState(() => _nearby = []);
      return;
    }
    try {
      final l = await api.nearbyDrivers(
        pointOf(d, 'pickup')!,
        companyId: d['forIndependents'] == true
            ? kIndependentId
            : d['targetCompanyId'] as String?,
      );
      if (mounted) setState(() => _nearby = l);
    } catch (_) {}
  }

  /// Délai d'expiration des commandes fixé par l'admin (0 = jamais)
  Future<void> _loadExpiry() async {
    try {
      final g = await api.grid();
      if (mounted) {
        setState(
          () => _expiryMin = (g['orderExpiryMin'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (_) {}
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
        fitPoints(_map, [...pts, ...r.points], padding: _fitPad());
      }
    } catch (_) {}
  }

  /// Marges du cadrage : la partie de la carte cachée par le panneau est exclue
  EdgeInsets _fitPad({double side = 40}) {
    final h = MediaQuery.sizeOf(context).height;
    return EdgeInsets.fromLTRB(side, 100, side, h * _sheetExtent.value + 30);
  }

  /// Décalage pour centrer un point dans la partie visible de la carte (au-dessus du panneau)
  Offset get _visibleCenterOffset =>
      Offset(0, -MediaQuery.sizeOf(context).height * _sheetExtent.value / 2);

  List<LatLng> get _allPoints => [
    if (_d != null) pointOf(_d!, 'pickup')!,
    for (final s in _stops)
      LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()),
  ];

  void _fit() {
    if (_mapReady && _d != null) {
      fitPoints(_map, [..._allPoints, ...?_route?.points], padding: _fitPad());
    }
  }

  /// Au premier point GPS du livreur : cadre le livreur et sa prochaine étape
  void _fitDriver() {
    if (_driverFitted || !_mapReady || _d == null || _driverPos == null) return;
    _fitDriverAndNext();
    _driverFitted = true;
  }

  void _fitDriverAndNext() {
    if (!_mapReady || _d == null || _driverPos == null) return;
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
    fitPoints(_map, [_driverPos, next], padding: _fitPad(side: 70));
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
    if (o['independent'] == true &&
        !await confirm(
          context,
          'Accepter un livreur indépendant ?',
          message: IndependentNotice.text,
          ok: 'Accepter',
        )) {
      return;
    }
    try {
      await api.acceptOffer(o['id']);
      hapticSuccess();
      if (mounted) {
        showInfo(
          context,
          '${o['driver']['name']} arrive pour ${formatMoney(o['price'], _d?['currency'])}',
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
    final reason = await pickCancelReason(
      context,
      side: 'client',
      title: 'Annuler la livraison ?',
      message: fee > 0
          ? 'Le livreur est déjà en route : des frais de déplacement de ${formatMoney(fee, _d?['currency'])} seront dus à son entreprise.'
          : enRoute
          ? 'Le livreur sera prévenu immédiatement.'
          : null,
    );
    if (reason == null) return;
    try {
      await api.cancel(widget.id, reason: reason);
      hapticSuccess();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Retirer un arrêt (un client de la boutique annule)
  Future<void> _cancelStop(Map<String, dynamic> stop) async {
    final pickedUp = _d?['status'] == 'PICKED_UP';
    final reason = await pickCancelReason(
      context,
      side: 'client',
      title: 'Annuler la livraison de ${stop['recipientName']} ?',
      message: pickedUp
          ? 'Le colis est déjà chez le livreur : le prix reste le même et le colis vous sera rapporté.'
          : 'Le prix et l’itinéraire seront recalculés, le livreur est prévenu.',
    );
    if (reason == null) return;
    try {
      await api.cancelStop(widget.id, stop['id'], reason: reason);
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
    final h = MediaQuery.sizeOf(context).height;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: p.background,
      body: NotificationListener<DraggableScrollableNotification>(
        onNotification: (n) {
          _sheetExtent.value = n.extent;
          return false;
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Stack(
                children: [
                  LetoMap(
                    controller: _map,
                    center: d == null ? abidjan : pointOf(d, 'pickup')!,
                    onReady: () {
                      _mapReady = true;
                      _fit();
                    },
                    // L'utilisateur déplace la carte : la caméra arrête de suivre le livreur
                    onMove: (_, gesture) {
                      if (gesture && _follow) setState(() => _follow = false);
                    },
                    layers: [
                      if (_route != null) routeLayer(_route!.points),
                      if (d != null && d['status'] == 'PENDING') ...[
                        AnimatedBuilder(
                          animation: _radar,
                          builder: (_, _) => CircleLayer(
                            circles: [
                              for (final k in const [0.0, 0.5])
                                _pulse(
                                  pointOf(d, 'pickup')!,
                                  (_radar.value + k) % 1,
                                ),
                            ],
                          ),
                        ),
                        MarkerLayer(
                          markers: [
                            for (final n in _nearby)
                              nearbyDriverMarker(n.point, n.vehicle),
                          ],
                        ),
                      ],
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
                      // Ma position, si je la partage avec le livreur
                      if (_sharing && _myPos != null)
                        MarkerLayer(markers: [myMarker(_myPos!)]),
                      // Livreur en temps réel : avance en continu, orienté dans son sens de marche
                      if (_driverPos != null && d != null && _active(d))
                        ValueListenableBuilder<LatLng?>(
                          valueListenable: _livePos,
                          builder: (_, pos, _) => MarkerLayer(
                            markers: [
                              if (pos != null)
                                driverMarker(
                                  pos,
                                  vehicle:
                                      d['driver']?['vehicleType'] ??
                                      d['vehicleType'],
                                  headingTurns: _hasHeading
                                      ? _headingTurns
                                      : null,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
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
            // Suivre le livreur : bouton posé juste au-dessus du panneau
            if (_driverPos != null && d != null && _active(d))
              ValueListenableBuilder<double>(
                valueListenable: _sheetExtent,
                builder: (_, extent, child) => Positioned(
                  right: 12,
                  bottom: h * extent + 12,
                  child: AnimatedOpacity(
                    opacity: extent > 0.75 ? 0 : 1,
                    duration: Motion.fast,
                    child: child,
                  ),
                ),
                child: Semantics(
                  label: _follow
                      ? 'Arrêter de suivre le livreur'
                      : 'Suivre le livreur',
                  child: MapButton(
                    _follow
                        ? CupertinoIcons.location_fill
                        : CupertinoIcons.location,
                    onTap: _toggleFollow,
                  ),
                ),
              ),
            DraggableScrollableSheet(
              controller: _sheet,
              initialChildSize: _sheetMid,
              minChildSize: _sheetMin,
              maxChildSize: _sheetMax,
              snap: true,
              snapSizes: const [_sheetMid],
              builder: (ctx, scroll) => DecoratedBox(
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(30),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 30,
                      offset: Offset(0, -6),
                    ),
                  ],
                ),
                child: ListView(
                  controller: scroll,
                  padding: EdgeInsets.fromLTRB(
                    20,
                    0,
                    20,
                    24 + bottomInset + (_finished ? 72 : 0),
                  ),
                  children: [
                    // Poignée : un appui agrandit ou réduit le panneau
                    Semantics(
                      button: true,
                      label: 'Agrandir ou réduire le détail de la livraison',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleSheet,
                        child: const Padding(
                          padding: EdgeInsets.only(top: 10, bottom: 14),
                          child: Grabber(),
                        ),
                      ),
                    ),
                    if (d == null)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: CupertinoActivityIndicator(),
                      )
                    else
                      ..._panel(d, p),
                  ],
                ),
              ),
            ),
            // Course terminée : « Terminer » toujours visible en bas
            if (d != null && _finished)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: p.card,
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + bottomInset),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Terminer'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleSheet() {
    hapticTap();
    final open = _sheetExtent.value < (_sheetMid + _sheetMax) / 2;
    _sheet.animateTo(
      open ? _sheetMax : _sheetMid,
      duration: Motion.medium,
      curve: Motion.curve,
    );
  }

  /// Onde radar autour du départ (t de 0 à 1 : s'élargit et s'efface)
  CircleMarker _pulse(LatLng center, double t) => CircleMarker(
    point: center,
    radius: 60 + 900 * t,
    useRadiusInMeter: true,
    color: accent.withValues(alpha: 0.16 * (1 - t)),
    borderColor: accent.withValues(alpha: 0.4 * (1 - t)),
    borderStrokeWidth: 2,
  );

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
      if (status == 'PENDING') ...[
        SearchingHeader(
          createdAt:
              DateTime.tryParse(d['createdAt'] ?? '')?.toLocal() ??
              DateTime.now(),
          nearby: _nearby.length,
          expiryMin: _expiryMin,
          price: formatMoney(d['price'], d['currency']),
          targeted: d['targetCompanyId'] != null,
        ),
        const SizedBox(height: 14),
      ] else ...[
        _header(d, p, fallback: title),
        const SizedBox(height: 18),
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
            currency: d['currency'],
            secondsLeft: _secondsLeft(o),
            onAccept: () => _acceptOffer(o),
            onDecline: () => _declineOffer(o),
          ),
        const SizedBox(height: 6),
      ],
      if (status != 'CANCELLED' && status != 'PENDING')
        DeliveryProgress(
          status,
          vehicle: d['driver']?['vehicleType'] ?? d['vehicleType'],
        ),
      const SizedBox(height: 18),
      _actions(d, p),
      if (_active(d) && d['driver'] != null) ...[
        const SizedBox(height: 16),
        InsetGroup(
          margin: EdgeInsets.zero,
          children: [
            GroupSwitch(
              leading: IconBadge(CupertinoIcons.location_fill, color: p.blue),
              title: 'Montrer au livreur où je me trouve',
              subtitle: _sharing
                  ? 'Le livreur voit votre position en direct'
                  : 'Utile s’il vous cherche au point de rendez-vous',
              value: _sharing,
              onChanged: (v) =>
                  v ? _startSharing() : _stopSharing(notify: true),
            ),
          ],
        ),
      ],
      // Commande expirée (aucun livreur dans le délai fixé par LETO)
      if (status == 'CANCELLED' && d['cancelledBy'] == 'Expiration')
        _notice(
          p,
          icon: CupertinoIcons.clock_fill,
          color: p.yellow,
          title: 'Commande expirée',
          text:
              '${d['cancelReason'] ?? 'Aucun livreur n’a accepté à temps'}. Repassez la commande depuis l’accueil.',
        ),
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
          title:
              'Frais de déplacement : ${formatMoney(d['cancellationFee'], d['currency'])}',
          text: d['cancellationFeeSettledAt'] != null
              ? 'Réglés auprès de l’entreprise de livraison.'
              : 'Le livreur était en route. À régler auprès de l’entreprise de livraison.',
        ),
        const SizedBox(height: 12),
      ],
      if (status == 'DELIVERED' && d['driver'] != null) ...[
        RatingCard(delivery: d, onRated: (nd) => setState(() => _d = nd)),
        const SizedBox(height: 16),
      ],
      // ----- Paiement et détails -----
      InsetGroup(
        margin: const EdgeInsets.only(bottom: 18),
        children: [
          GroupRow(
            leading: IconBadge(
              CupertinoIcons.money_dollar_circle_fill,
              color: p.green,
            ),
            title: 'Espèces',
            subtitle: 'Paiement au livreur',
            trailing: Text(
              formatMoney(d['price'], d['currency']),
              style: TextStyles.headline.copyWith(color: p.label),
            ),
          ),
          GroupRow(
            leading: IconBadge(CupertinoIcons.info, color: p.secondaryLabel),
            title: 'Détails de la commande',
            subtitle: [
              vehicleLabels[d['vehicleType']],
              speedLabels[d['speed']],
              if (d['distanceKm'] != null) km(d['distanceKm']),
            ].whereType<String>().join(' · '),
            chevron: true,
            onTap: () => showOrderDetails(context, d),
          ),
        ],
      ),
      // ----- Expéditeur -----
      Text('Expéditeur', style: TextStyles.headline.copyWith(color: p.label)),
      const SizedBox(height: 6),
      InsetGroup(
        margin: const EdgeInsets.only(bottom: 18),
        children: [
          GroupRow(
            leading: IconBadge(CupertinoIcons.phone_fill, color: p.green),
            title: formatPhone(d['pickupPhone']),
            subtitle:
                (d['pickupContactName'] ?? d['client']?['name']) as String?,
            onTap: () => callPhone(context, d['pickupPhone']),
          ),
          GroupRow(
            leading: const IconBadge(CupertinoIcons.circle_fill, color: ink),
            title: d['pickupAddress'] ?? '',
            subtitle: [
              d['pickupCommune'],
              d['pickupDetails'],
            ].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
          ),
          if ((d['courierComment'] ?? '').toString().isNotEmpty)
            GroupRow(
              leading: IconBadge(
                CupertinoIcons.chat_bubble_text_fill,
                color: p.blue,
              ),
              title: d['courierComment'],
              subtitle: 'Instructions pour le livreur',
            ),
        ],
      ),
      // ----- Destinataires -----
      Row(
        children: [
          Text(
            n > 1 ? 'Destinataires' : 'Destinataire',
            style: TextStyles.headline.copyWith(color: p.label),
          ),
          const Spacer(),
          if (api.deliveryCodeEnabled &&
              !_finished &&
              _stops.any((s) => s['status'] == 'PENDING'))
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
      // Annuler : à part, tout en bas, loin des actions courantes
      if (status == 'PENDING' || status == 'ACCEPTED') ...[
        const SizedBox(height: 22),
        Center(
          child: RoundAction(
            icon: RoundIcon(CupertinoIcons.xmark, color: p.red),
            label: status == 'PENDING'
                ? 'Annuler la demande'
                : 'Annuler la livraison',
            onTap: _cancel,
          ),
        ),
        const SizedBox(height: 8),
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

  /// Titre « quand ? » : prise en charge / livraison dans ≈ N min, avec une phrase de contexte
  (String, String?) _headline(Map<String, dynamic> d, String fallback) {
    final status = d['status'] as String;
    final eta = _etaMin(d);
    final driver = (d['driver']?['name'] as String?)?.split(' ').first;
    final pending = _stops.where((s) => s['status'] == 'PENDING').toList();
    final next = pending.firstOrNull;
    final n = _stops.length;
    final done = _stops.where((s) => s['status'] == 'DELIVERED').length;
    switch (status) {
      case 'ACCEPTED':
        return (
          eta != null ? 'Prise en charge dans ≈$eta min' : fallback,
          '${driver ?? 'Le livreur'} se rend au point de départ pour récupérer le colis.',
        );
      case 'PICKED_UP':
        if (next != null && next['arrivedAt'] != null) {
          return (
            'Le livreur est arrivé',
            'Chez ${next['recipientName']} · ${next['address']}',
          );
        }
        return (
          eta != null ? 'Livraison dans ≈$eta min' : fallback,
          n > 1
              ? 'Tournée : $done/$n livrés. Prochain arrêt : ${next?['recipientName'] ?? '—'}.'
              : 'Colis récupéré : ${driver ?? 'le livreur'} se dirige vers ${next?['recipientName'] ?? 'le destinataire'}.',
        );
      case 'DELIVERED':
        final t = DateTime.tryParse(d['deliveredAt'] ?? '')?.toLocal();
        return (
          fallback == 'Livraison terminée' ? 'Livré' : fallback,
          t == null
              ? null
              : 'Le ${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} à ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        );
      default:
        return (fallback, d['cancelReason'] as String?);
    }
  }

  Widget _header(
    Map<String, dynamic> d,
    Palette p, {
    required String fallback,
  }) {
    final (title, subtitle) = _headline(d, fallback);
    final driver = d['driver'] as Map?;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyles.title1.copyWith(color: p.label)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (driver != null && d['status'] != 'CANCELLED') ...[
          const SizedBox(width: 12),
          VehiclePlate(
            vehicle: driver['vehicleType'] ?? d['vehicleType'],
            plate: driver['plate'],
          ),
        ],
      ],
    );
  }

  /// Rangée d'actions : livreur, appeler, partager le suivi, détails, répéter
  Widget _actions(Map<String, dynamic> d, Palette p) {
    final driver = d['driver'] as Map?;
    final active = _active(d);
    final items = <Widget>[
      if (driver != null)
        RoundAction(
          icon: DriverPhoto(driver),
          label: driver['name'] ?? '',
          onTap: () => showOrderDetails(context, d),
        ),
      if (driver != null && (active || d['status'] == 'DELIVERED'))
        RoundAction(
          icon: const RoundIcon(CupertinoIcons.phone_fill),
          label: 'Appeler le livreur',
          onTap: () => callPhone(context, driver['phone']),
        ),
      if (trackingUrl(d) != null && !_finished)
        Builder(
          builder: (ctx) => RoundAction(
            icon: const RoundIcon(CupertinoIcons.arrowshape_turn_up_right_fill),
            label: 'Partager le suivi',
            onTap: () => _shareTracking(ctx, d),
          ),
        ),
      RoundAction(
        icon: const RoundIcon(CupertinoIcons.info),
        label: 'Détails',
        onTap: () => showOrderDetails(context, d),
      ),
      if (_finished)
        RoundAction(
          icon: const RoundIcon(CupertinoIcons.arrow_clockwise, color: accent),
          label: 'Répéter',
          onTap: () => _repeat(d),
        ),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items,
    );
  }

  /// Repasser la même commande : l'accueil reprend le départ et les destinataires
  void _repeat(Map<String, dynamic> d) {
    hapticTap();
    repeatOrder.value = d;
    Navigator.of(context).popUntil((r) => r.isFirst);
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
              if (status == 'PENDING' && Api.instance.deliveryCodeEnabled) ...[
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
          // Coordonnées du destinataire : téléphone (appel), précisions, colis
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => callPhone(context, stop['recipientPhone']),
                  child: Text(
                    formatPhone(stop['recipientPhone']),
                    style: TextStyles.footnote.copyWith(
                      color: p.blue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (subtitle != stop['address'])
                  Text(
                    '${stop['address']} (${stop['commune']})',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                if ((stop['details'] ?? '').toString().isNotEmpty)
                  Text(
                    stop['details'],
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                if ((stop['packageDescription'] ?? '').toString().isNotEmpty)
                  Text(
                    'Colis : ${stop['packageDescription']}',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
              ],
            ),
          ),
          if (cod > 0 && status != 'FAILED')
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Pill(
                stop['codRemittedAt'] != null
                    ? '${formatMoney(cod, d['currency'])} reversé'
                    : status == 'DELIVERED'
                    ? '${formatMoney(cod, d['currency'])} encaissé'
                    : 'Encaisser ${formatMoney(cod, d['currency'])}',
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
  final String? currency;
  final int secondsLeft;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _OfferTile({
    required this.offer,
    required this.original,
    this.currency,
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
              Avatar(
                offer['driver']['name'],
                radius: 20,
                photo: offer['driver']['avatarUrl'],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (offer['independent'] == true)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 3),
                        child: IndependentBadge(),
                      ),
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
                    formatMoney(offer['price'], currency),
                    style: TextStyles.title3.copyWith(
                      color: p.label,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '+${formatMoney(offer['price'] - original, currency)}',
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
