import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../live_activity.dart';
import '../live_route.dart';
import '../main.dart';
import '../realtime.dart';
import 'cancel_reasons.dart';
import 'map_picker.dart';
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  /// Trajet réel du livreur vers sa prochaine étape (recalé, consommé, recalculé s'il dévie)
  final _live = LiveRoute();
  DateTime _lastGesture = DateTime(2000);

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
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Actualisations périodiques : seulement quand l'écran est visible (ni arrière-plan, ni recouvert)
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_finished && _visible) _load();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      // Signal du livreur perdu / retrouvé : marqueur grisé et mention « position il y a… »
      if (_driverStale != _wasStale || (_driverStale && t.tick % 30 == 0)) {
        setState(() => _wasStale = _driverStale);
      }
      // Les comptes à rebours s'actualisent seuls (_Countdown) : on ne reconstruit l'écran qu'à l'expiration
      if (_offers.any((o) => _secondsLeft(o) <= 0)) {
        setState(() => _offers.removeWhere((o) => _secondsLeft(o) <= 0));
      }
    });
    _loadExpiry();
    _nearbyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_visible) _loadNearby();
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
    s.on('stop:help', _onHelp);
    _unsubscribe = Realtime.instance.onConnected(
      () => s.emit('delivery:watch', widget.id),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker?.cancel();
    _nearbyTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
    s.off('stop:help', _onHelp);
    s.emit('delivery:unwatch', widget.id);
    _unsubscribe?.call();
    super.dispose();
  }

  // ---------- Temps réel ----------

  /// Écran au premier plan et non recouvert par un autre écran
  bool get _visible =>
      mounted &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      TickerMode.getNotifier(context).value;

  /// Retour au premier plan : la connexion a pu tomber pendant l'arrière-plan
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final s = Realtime.instance.socket;
    if (!s.connected) s.connect();
    _load();
  }

  /// Dernière position reçue du livreur, et si elle n'est plus à jour (plus d'1 min)
  DateTime? _lastDriverFix;
  bool _wasStale = false;
  bool get _driverStale =>
      _lastDriverFix != null &&
      DateTime.now().difference(_lastDriverFix!).inSeconds > 60;

  void _onDriverLocation(dynamic e) {
    if (!mounted || e is! Map || e['deliveryId'] != widget.id) return;
    final gps = LatLng(
      (e['lat'] as num).toDouble(),
      (e['lng'] as num).toDouble(),
    );
    _lastDriverFix = DateTime.now();
    final next = _trackLive(gps);
    _animateDriver(next, heading: (e['heading'] as num?)?.toDouble());
    setState(() => _driverPos = next);
    _fitDriver();
    _keepInView();
    // Heure d'arrivée à jour dans la Live Activity (mise à jour seulement si elle change)
    final d = _d;
    if (d != null) {
      DeliveryLive.instance.sync(d, driver: false, etaMin: _etaMin(d));
    }
  }

  /// Prochaine étape du livreur : le départ, puis le prochain destinataire
  LatLng? _liveTarget(Map d) {
    if (d['status'] == 'ACCEPTED') return pointOf(d, 'pickup');
    if (d['status'] != 'PICKED_UP') return null;
    final s = _stops.where((s) => s['status'] == 'PENDING').firstOrNull;
    return s == null
        ? null
        : LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble());
  }

  /// Met à jour le trajet en direct et renvoie la position à afficher (recalée sur la route si proche)
  LatLng _trackLive(LatLng gps) {
    final d = _d;
    final target = d == null ? null : _liveTarget(d);
    if (target == null) {
      _live.clear();
      return gps;
    }
    if (_live.update(gps, target)) {
      final firstRoute = !_live.hasRoute;
      _live.fetch(gps).then((ok) {
        if (!ok || !mounted) return;
        setState(() {});
        // Premier trajet connu : cadrage sur le livreur, le trajet et l'étape (sauf si l'utilisateur a bougé la carte)
        if (firstRoute &&
            !_follow &&
            DateTime.now().difference(_lastGesture).inSeconds > 20) {
          _fitDriverAndNext();
        }
      });
    }
    final f = _live.fix;
    return f != null && f.offRouteM < 35 ? f.snapped : gps;
  }

  /// Sans suivi ni geste récent : recadre si le livreur sort de la partie visible de la carte
  void _keepInView() {
    if (_follow || !_mapReady || _driverPos == null) return;
    if (DateTime.now().difference(_lastGesture).inSeconds < 20) return;
    final size = MediaQuery.sizeOf(context);
    final o = _map.camera.latLngToScreenOffset(_driverPos!);
    final visibleBottom = size.height * (1 - _sheetExtent.value) - 30;
    if (o.dx < 30 ||
        o.dx > size.width - 30 ||
        o.dy < 90 ||
        o.dy > visibleBottom) {
      _fitDriverAndNext();
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

  /// Échec : l'expéditeur choisit tout de suite (nouvelle tentative ou retour), sinon le colis lui est rapporté
  Future<void> _onStopFailed(dynamic e) async {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    await _load();
    if (!mounted) return;
    final stop = _stops.where((s) => s['id'] == e['stopId']).firstOrNull;
    if (e['deciding'] == true && stop != null) {
      _chooseFollowUp(stop);
    } else {
      showInfo(
        context,
        'Colis non remis à ${e['recipientName']} : il vous est rapporté',
      );
    }
  }

  /// Le livreur est sur place et le destinataire ne répond pas
  Future<void> _onHelp(dynamic e) async {
    if (e is! Map || e['deliveryId'] != widget.id || !mounted) return;
    await _load();
    final stop = _stops.where((s) => s['id'] == e['stopId']).firstOrNull;
    if (stop != null && mounted) _answerHelp(stop);
  }

  /// Réponse au livreur : attendre, autre numéro / indications, ou annuler ce colis
  Future<void> _answerHelp(Map<String, dynamic> stop) async {
    final d = _d;
    if (d == null) return;
    final fee = api.stopFee(d, api.returnFeePct);
    final choice = await showActions<String>(
      context,
      title: '${stop['recipientName']} ne répond pas',
      message:
          'Le livreur est sur place et a appelé sans réponse. Que doit-il faire ?',
      actions: [
        ('Attendre 5 min de plus', 'WAIT', false),
        ('Donner un autre numéro ou des indications', 'UPDATE', false),
        (
          fee > 0
              ? 'Annuler ce colis (retour : ${formatMoney(fee, d['currency'])})'
              : 'Annuler ce colis (il vous est rapporté)',
          'CANCEL',
          true,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    String? phone, details;
    if (choice == 'UPDATE') {
      final contact = await _askContact();
      if (contact == null) return;
      (phone, details) = contact;
    }
    try {
      await api.answerHelp(
        widget.id,
        stop['id'],
        choice,
        recipientPhone: phone,
        details: details,
      );
      if (mounted) showInfo(context, 'Réponse envoyée au livreur');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Nouveau numéro et/ou indications (au moins l'un des deux)
  Future<(String?, String?)?> _askContact() async {
    final phone = await prompt(
      context,
      'Autre numéro du destinataire',
      message: 'Facultatif · laissez vide pour garder le même',
      placeholder: '07 00 00 00 00',
      keyboard: TextInputType.phone,
      ok: 'Suivant',
    );
    if (phone == null || !mounted) return null;
    final details = await prompt(
      context,
      'Indications pour le livreur',
      message: 'Facultatif · ex. : sonner au portail bleu, demander Awa',
      placeholder: 'Indications',
      ok: 'Envoyer',
    );
    if (details == null) return null;
    final ph = phone.trim(), de = details.trim();
    if (ph.isEmpty && de.isEmpty) {
      if (mounted)
        showError(context, 'Indiquez un autre numéro ou des indications');
      return null;
    }
    return (ph.isEmpty ? null : ph, de.isEmpty ? null : de);
  }

  /// Après un échec : nouvelle tentative (prix réduit) ou retour du colis (facturé)
  Future<void> _chooseFollowUp(Map<String, dynamic> stop) async {
    final d = _d;
    if (d == null) return;
    final cur = d['currency'];
    final retry = api.stopFee(d, api.retryFeePct);
    final back = api.stopFee(d, api.returnFeePct);
    final choice = await showActions<String>(
      context,
      title: 'Colis non remis à ${stop['recipientName']}',
      message: [
        '${failureLabels[stop['failureReason']] ?? 'Non livré'}${(stop['failureNote'] ?? '').toString().isNotEmpty ? ' · « ${stop['failureNote']} »' : ''}',
        'Sans réponse dans ${api.followUpAutoMin} min, le colis vous est rapporté.',
      ].join('\n'),
      actions: [
        (
          'Nouvelle tentative · même adresse (${formatMoney(retry, cur)})',
          'RETRY',
          false,
        ),
        ('Nouvelle tentative · autre numéro ou adresse', 'EDIT', false),
        ('Me rapporter le colis (${formatMoney(back, cur)})', 'RETURN', false),
      ],
      cancelLabel: 'Décider plus tard',
    );
    if (choice == null || !mounted) return;
    String? phone, details;
    Place? place;
    if (choice == 'EDIT') {
      final what = await showActions<String>(
        context,
        title: 'Nouvelle tentative (${formatMoney(retry, cur)})',
        message: 'Nouvelle adresse : à moins de 5 km de la première.',
        actions: [
          ('Autre numéro ou indications', 'CONTACT', false),
          ('Autre adresse', 'PLACE', false),
        ],
      );
      if (what == null || !mounted) return;
      if (what == 'CONTACT') {
        final contact = await _askContact();
        if (contact == null) return;
        (phone, details) = contact;
      } else {
        place = await Navigator.push<Place>(
          context,
          MaterialPageRoute(
            builder: (_) => MapPickerScreen(
              title: 'Nouvelle adresse',
              initial: LatLng(
                (stop['lat'] as num).toDouble(),
                (stop['lng'] as num).toDouble(),
              ),
            ),
          ),
        );
        if (place == null) return;
      }
    }
    try {
      await api.chooseFollowUp(
        widget.id,
        stop['id'],
        choice == 'RETURN' ? 'RETURN' : 'RETRY',
        recipientPhone: phone,
        details: details,
        place: place,
      );
      if (mounted) {
        showInfo(
          context,
          choice == 'RETURN'
              ? 'Le livreur vous rapporte le colis'
              : 'Nouvelle tentative demandée au livreur',
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
      api.returnCodeEnabled
          ? 'Le livreur vous rapporte ${e['parcels']} colis : donnez-lui votre code de retour'
          : 'Le livreur vous rapporte ${e['parcels']} colis',
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
      // Filet de sécurité : position enregistrée par le serveur plus récente que la dernière reçue
      // en direct (connexion tombée, retour d'arrière-plan) → le livreur avance quand même
      final driver = d['driver'];
      final savedAt = DateTime.tryParse(
        driver?['lastLocationAt'] ?? '',
      )?.toLocal();
      if (_active(d) &&
          savedAt != null &&
          driver['lastLat'] != null &&
          (_lastDriverFix == null ||
              savedAt.difference(_lastDriverFix!).inSeconds > 5)) {
        _onDriverLocation({
          'deliveryId': widget.id,
          'lat': driver['lastLat'],
          'lng': driver['lastLng'],
        });
        _lastDriverFix = savedAt;
      } else if (_driverPos != null && _active(d)) {
        // Trajet réel dès l'ouverture, puis à chaque changement d'étape
        final shown = _trackLive(_driverPos!);
        if (shown != _driverPos) setState(() => _driverPos = shown);
      }
      // Ondes radar : seulement pendant la recherche d'un livreur
      final searching = d['status'] == 'PENDING';
      if (searching && !_radar.isAnimating) {
        _radar.repeat();
      } else if (!searching && _radar.isAnimating) {
        _radar.stop();
      }
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
    // Le livreur, sa prochaine étape et le trajet qui les relie
    fitPoints(_map, [
      _driverPos,
      next,
      ..._live.remaining,
    ], padding: _fitPad(side: 60));
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

  /// Contre-proposition : un prix entre le prix affiché (+50) et celui du livreur (−50)
  Future<void> _counterOffer(Map o) async {
    final cur = _d?['currency'] as String?;
    final min =
        (o['minCounter'] as num?)?.toInt() ??
        ((_d?['price'] as num).toInt() + 50);
    final max = (o['price'] as num).toInt() - 50;
    if (max < min)
      return showError(
        context,
        'Proposition trop proche du prix affiché : acceptez-la ou refusez-la',
      );
    final mid = (((min + max) / 2) / 50).round() * 50;
    final value = await prompt(
      context,
      'Votre prix',
      message:
          '${o['driver']['name']} propose ${formatMoney(o['price'], cur)}. Proposez entre ${formatMoney(min, cur)} et ${formatMoney(max, cur)}.',
      initial: '$mid',
      keyboard: TextInputType.number,
      ok: 'Proposer',
      large: true,
    );
    final price = int.tryParse((value ?? '').replaceAll(RegExp(r'\D'), ''));
    if (price == null) return;
    try {
      await api.counterOffer(o['id'], price);
      hapticSuccess();
      if (mounted)
        showInfo(context, 'Proposition envoyée à ${o['driver']['name']}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _loadOffers();
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
          showError(
            context,
            preview['reason'] ?? 'Cette livraison ne peut plus être annulée',
          );
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
                      if (!gesture) return;
                      _lastGesture = DateTime.now();
                      if (_follow) setState(() => _follow = false);
                    },
                    layers: [
                      // Tournée prévue (estompée pendant la course) et trajet réel du livreur par-dessus
                      if (_route != null)
                        routeLayer(
                          _route!.points,
                          color: d != null && _active(d) && _live.hasRoute
                              ? accent.withValues(alpha: 0.3)
                              : accent,
                        ),
                      if (d != null && _active(d) && _live.hasRoute)
                        routeLayer(_live.remaining, color: p.blue),
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
                                  stale: _driverStale,
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
                  PhosphorIconsBold.caretLeft,
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
                        ? PhosphorIconsFill.navigationArrow
                        : PhosphorIconsBold.navigationArrow,
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
            : 'Terminée · $delivered livré(s), $failed non livré(s)',
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
            expiresAt: DateTime.parse(o['expiresAt']),
            onAccept: () => _acceptOffer(o),
            onDecline: () => _declineOffer(o),
            onCounter: () => _counterOffer(o),
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
              leading: IconBadge(
                PhosphorIconsFill.navigationArrow,
                color: p.blue,
              ),
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
      // Commande expirée (aucun livreur dans le délai fixé par VITE)
      if (status == 'CANCELLED' && d['cancelledBy'] == 'Expiration')
        _notice(
          p,
          icon: PhosphorIconsFill.clock,
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
                    icon: PhosphorIconsFill.clock,
                    color: p.yellow,
                    title: 'Pas encore de réponse de l’entreprise choisie',
                    text:
                        'Ouvrir la course à tous les livreurs disponibles (même prix) ?',
                    onTap: _openToAll,
                  )
                : _notice(
                    p,
                    icon: PhosphorIconsFill.buildings,
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
          icon: PhosphorIconsFill.arrowUDownLeft,
          color: accent,
          title: 'Colis en retour',
          text: api.returnCodeEnabled
              ? 'Le livreur vous rapporte les colis non livrés. Donnez-lui ce code en les récupérant.'
              : 'Le livreur vous rapporte les colis non livrés au point de départ.',
          trailing: api.returnCodeEnabled
              ? Text(
                  d['returnCode'] ?? '',
                  style: TextStyles.title2.copyWith(
                    color: p.label,
                    letterSpacing: 4,
                  ),
                )
              : null,
        ),
        const SizedBox(height: 12),
      ],
      if (d['returnedAt'] != null) ...[
        _notice(
          p,
          icon: PhosphorIconsFill.sealCheck,
          color: p.green,
          title: 'Colis non livrés récupérés',
          text: 'Le livreur vous a rendu les colis.',
        ),
        const SizedBox(height: 12),
      ],
      // Livreur sur place, destinataire injoignable : il attend la réponse
      for (final s in _stops.where(
        (s) =>
            s['status'] == 'PENDING' &&
            s['helpRequestedAt'] != null &&
            s['helpAnswer'] == null,
      )) ...[
        _notice(
          p,
          icon: PhosphorIconsFill.phone,
          color: p.yellow,
          title: '${s['recipientName']} ne répond pas',
          text: 'Le livreur est sur place. Dites-lui quoi faire.',
          onTap: () => _answerHelp(s),
        ),
        const SizedBox(height: 12),
      ],
      // Échec : nouvelle tentative ou retour ?
      for (final s in _stops.where(
        (s) => s['status'] == 'FAILED' && s['followUp'] == 'DECIDING',
      )) ...[
        _notice(
          p,
          icon: PhosphorIconsFill.warningCircle,
          color: p.yellow,
          title: 'Colis non remis à ${s['recipientName']}',
          text:
              'Choisissez une nouvelle tentative ou le retour du colis. Sans réponse, il vous est rapporté.',
          onTap: () => _chooseFollowUp(s),
        ),
        const SizedBox(height: 12),
      ],
      for (final s in _stops.where(
        (s) => s['status'] == 'PENDING' && s['cancelRequestedAt'] != null,
      )) ...[
        _notice(
          p,
          icon: PhosphorIconsFill.warningCircle,
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
          icon: PhosphorIconsFill.money,
          color: accent,
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
            leading: IconBadge(PhosphorIconsFill.money, color: p.green),
            title: 'Espèces',
            subtitle: ((d['extraFees'] ?? 0) as num) > 0
                ? 'Paiement au livreur · dont ${formatMoney(d['extraFees'], d['currency'])} de retour ou nouvelle tentative'
                : 'Paiement au livreur',
            trailing: Text(
              formatMoney(
                (d['price'] as num) + ((d['extraFees'] ?? 0) as num),
                d['currency'],
              ),
              style: TextStyles.headline.copyWith(color: p.label),
            ),
          ),
          GroupRow(
            leading: IconBadge(PhosphorIconsBold.info, color: p.secondaryLabel),
            title: 'Détails de la commande',
            subtitle: [
              if (d['vehicleType'] != null) vehicleName(d['vehicleType']),
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
            leading: IconBadge(PhosphorIconsFill.phone, color: p.green),
            title: formatPhone(d['pickupPhone']),
            subtitle:
                (d['pickupContactName'] ?? d['client']?['name']) as String?,
            onTap: () => callPhone(context, d['pickupPhone']),
          ),
          GroupRow(
            leading: const IconBadge(PhosphorIconsFill.circle, color: ink),
            title: d['pickupAddress'] ?? '',
            subtitle: [
              d['pickupCommune'],
              d['pickupDetails'],
            ].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
          ),
          if ((d['courierComment'] ?? '').toString().isNotEmpty)
            GroupRow(
              leading: IconBadge(PhosphorIconsFill.chatText, color: p.blue),
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
            icon: RoundIcon(PhosphorIconsBold.x, color: p.red),
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
              PhosphorIconsBold.caretRight,
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
    // Trajet réel connu : temps restant sur l'itinéraire
    if (_live.hasRoute && _live.etaMin != null) return _live.etaMin;
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
        text: 'Suivez ma livraison VITE en direct : $url',
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
          '${driver ?? 'Le livreur'} vient récupérer le colis.',
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
        // Commande expirée : le motif est déjà dans l'encadré « Commande expirée »
        return (
          fallback,
          d['cancelledBy'] == 'Expiration'
              ? null
              : d['cancelReason'] as String?,
        );
    }
  }

  Widget _header(
    Map<String, dynamic> d,
    Palette p, {
    required String fallback,
  }) {
    final (title, subtitle) = _headline(d, fallback);
    final staleMin = _driverStale && _active(d)
        ? math.max(
            1,
            (DateTime.now().difference(_lastDriverFix!).inSeconds / 60).round(),
          )
        : null;
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
              if (staleMin != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      PhosphorIconsBold.broadcast,
                      size: 15,
                      color: p.yellow,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Position du livreur mise à jour il y a $staleMin min',
                        style: TextStyles.footnote.copyWith(color: p.yellow),
                      ),
                    ),
                  ],
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
          icon: const RoundIcon(PhosphorIconsFill.phone),
          label: 'Appeler le livreur',
          onTap: () => callPhone(context, driver['phone']),
        ),
      if (trackingUrl(d) != null && !_finished)
        Builder(
          builder: (ctx) => RoundAction(
            icon: const RoundIcon(PhosphorIconsFill.shareFat),
            label: 'Partager le suivi',
            onTap: () => _shareTracking(ctx, d),
          ),
        ),
      // Sans livreur : accès direct au détail (sinon, sa photo ouvre déjà la même fiche)
      if (driver == null)
        RoundAction(
          icon: const RoundIcon(PhosphorIconsBold.info),
          label: 'Détails',
          onTap: () => showOrderDetails(context, d),
        ),
      if (_finished)
        RoundAction(
          icon: const RoundIcon(
            PhosphorIconsBold.arrowClockwise,
            color: accent,
          ),
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
        '${failureLabels[stop['failureReason']]} · ${_time(stop['failedAt'])}${stop['followUp'] == 'RETURN' ? ' · colis rapporté' : ''}',
      'CANCELLED' =>
        'Annulé · ${_time(stop['cancelledAt'])}${stop['cancelReason'] != null ? ' · ${stop['cancelReason']}' : ''}',
      _ =>
        stop['arrivedAt'] != null
            ? 'Le livreur est sur place'
            : (stop['attempt'] ?? 1) > 1
            ? 'Nouvelle tentative'
            : stop['address'],
    };
    final fees =
        ((stop['returnFee'] ?? 0) as num) + ((stop['retryFee'] ?? 0) as num);
    final past = ((stop['pastAttempts'] as List?) ?? []);
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
                        PhosphorIconsBold.check,
                        color: Colors.white,
                        size: 16,
                      )
                    : status == 'CANCELLED'
                    ? const Icon(
                        PhosphorIconsBold.minus,
                        color: Colors.white,
                        size: 14,
                      )
                    : status == 'FAILED'
                    ? const Icon(
                        PhosphorIconsBold.x,
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
                    child: Icon(
                      PhosphorIconsBold.shareNetwork,
                      size: 20,
                      color: p.blue,
                    ),
                  ),
                ),
                if (onCancel != null)
                  CupertinoButton(
                    padding: const EdgeInsets.only(left: 10),
                    minimumSize: Size.zero,
                    onPressed: onCancel,
                    child: Icon(
                      PhosphorIconsFill.xCircle,
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
                icon: PhosphorIconsBold.creditCard,
              ),
            ),
          // ----- Tentative précédente et frais -----
          if (past.isNotEmpty || fees > 0)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in past)
                    Pill(
                      '1er passage : ${failureLabels[a['reason']] ?? 'non livré'}',
                      color: p.secondaryLabel,
                      icon: PhosphorIconsBold.clock,
                    ),
                  if ((stop['retryFee'] ?? 0) > 0)
                    Pill(
                      'Nouvelle tentative ${formatMoney(stop['retryFee'], d['currency'])}',
                      color: accentDeep,
                      icon: PhosphorIconsBold.arrowClockwise,
                    ),
                  if ((stop['returnFee'] ?? 0) > 0)
                    Pill(
                      'Retour ${formatMoney(stop['returnFee'], d['currency'])}',
                      color: accentDeep,
                      icon: PhosphorIconsBold.arrowUDownLeft,
                    ),
                ],
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
                                icon: PhosphorIconsBold.flag,
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
  final DateTime expiresAt;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onCounter;
  const _OfferTile({
    required this.offer,
    required this.original,
    this.currency,
    required this.expiresAt,
    required this.onAccept,
    required this.onDecline,
    required this.onCounter,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final countered = offer['counterPrice'] != null;
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
          if (countered) ...[
            const SizedBox(height: 10),
            Text(
              'Vous proposez ${formatMoney(offer['counterPrice'], currency)} · en attente de la réponse du livreur',
              style: TextStyles.footnote.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              _Countdown(expiresAt),
              const Spacer(),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: onDecline,
                child: Text(
                  'Refuser',
                  style: TextStyles.body.copyWith(color: p.secondaryLabel),
                ),
              ),
              if (!countered)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: onCounter,
                  child: Text(
                    'Contre-proposer',
                    style: TextStyles.body.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              FilledButton(
                onPressed: onAccept,
                child: Text(
                  countered
                      ? 'Accepter ${formatMoney(offer['price'], currency)}'
                      : 'Accepter',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compte à rebours « m:ss » qui se redessine seul chaque seconde (sans reconstruire l'écran)
class _Countdown extends StatefulWidget {
  final DateTime until;
  const _Countdown(this.until);
  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Timer _t = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _t;
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = math.max(0, widget.until.difference(DateTime.now()).inSeconds);
    return Text(
      '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}',
      style: TextStyles.footnote.copyWith(
        color: Palette.of(context).secondaryLabel,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
