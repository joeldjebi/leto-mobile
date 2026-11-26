import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../live_activity.dart';
import '../live_route.dart';
import '../main.dart';
import '../notifications.dart';
import '../realtime.dart';
import 'driver_course_sheet.dart';
import 'documents_screen.dart';
import 'payroll_screen.dart';
import 'independent_screens.dart';
import 'logbook_screen.dart';
import 'cancel_reasons.dart';
import 'order_alert.dart';
import 'widgets.dart';

/// Dev / tests : photo déjà envoyée utilisée à la place de l'appareil photo (--dart-define=DEV_PHOTO=/uploads/x.jpg)
const _devPhoto = String.fromEnvironment('DEV_PHOTO');

/// Accueil livreur : carte plein écran + panneau (Courses · En cours · Gains)
class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> with WidgetsBindingObserver {
  final api = Api.instance;
  final _map = MapController();

  int _tab = 0;
  ScrollController? _sheetScroll;
  bool _online = false;
  LatLng? _me;
  Timer? _timer;
  Timer? _heartbeat;
  Timer? _clock;
  /// Surveille la connexion temps réel (iPhone : coupée en arrière-plan, parfois sans le signaler)
  Timer? _watchdog;
  DateTime? _pausedAt;
  void Function()? _offConnect;
  StreamSubscription<Position>? _gps;
  int _absenceWaitMin = 5;

  List<Map<String, dynamic>> _available = [];

  /// Gains et versements (onglet « Gains »)
  Map<String, dynamic>? _cash;

  /// Raison du blocage par l'entreprise (abonnement expiré, crédit épuisé), sinon null
  String? _blocked;
  List<Map<String, dynamic>> _mine = [];
  Map<String, Map<String, dynamic>> _myOffers = {};

  /// Itinéraire en direct vers la prochaine étape (recalculé si le livreur dévie, consommé au fil du trajet)
  final _nav = LiveRoute();

  /// Mode navigation : la carte suit le livreur, orientée dans son sens de marche
  bool _navMode = false;
  double _headingDeg = 0;
  double _headingTurns = 0;
  bool _hasHeading = false;
  bool _autoTracking = false;
  final _sheetExtent = ValueNotifier<double>(0.5);

  List<Map<String, dynamic>> get _active => _mine
      .where((d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']))
      .toList();

  /// Tournée : ordre de passage de toutes les étapes (P:course, S:arrêt, R:retour), donné par le serveur
  List<String> _plan = [];
  num? _planKm;
  num? _planBestKm;

  /// Course de la première étape de la tournée
  String? get _planCourseId {
    for (final k in _plan) {
      final id = _courseOfKey(k);
      if (id != null) return id;
    }
    return null;
  }

  /// Course affichée dans « En cours » : celle choisie par le livreur, sinon celle de la prochaine étape
  String? _selectedId;
  Map<String, dynamic>? get _current => _active.isEmpty
      ? null
      : _active.where((d) => d['id'] == _selectedId).firstOrNull ??
            _active.where((d) => d['id'] == _planCourseId).firstOrNull ??
            _active.first;

  /// Règles de répartition (Tarifs et règles) : courses en même temps, rayon du livreur occupé
  int _maxActive = 3;
  num _busyRadiusKm = 2;

  List<Map<String, dynamic>> _stopsOf(Map d) =>
      ((d['stops'] as List?) ?? []).cast<Map<String, dynamic>>();

  /// Prochain arrêt : d'abord ceux sans annulation en attente de confirmation
  Map<String, dynamic>? _nextStop(Map d) {
    final pending = _stopsOf(d).where((s) => s['status'] == 'PENDING');
    return pending.where((s) => s['cancelRequestedAt'] == null).firstOrNull ??
        pending.firstOrNull;
  }

  /// Colis non livrés à rapporter à l'expéditeur
  bool _returning(Map d) =>
      d['returnRequired'] == true &&
      d['returnedAt'] == null &&
      _nextStop(d) == null;
  LatLng _pt(Map s) =>
      LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble());

  /// Prochaine destination : le départ, puis chaque arrêt en attente
  LatLng? _targetOf(Map d) {
    if (d['status'] == 'ACCEPTED' || _returning(d)) return pointOf(d, 'pickup');
    final s = _nextStop(d);
    return s == null ? null : _pt(s);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    api
        .grid()
        .then((g) {
          _absenceWaitMin = (g['absenceWaitMin'] as num?)?.ceil() ?? 5;
          _maxActive = (g['maxActiveCourses'] as num?)?.toInt() ?? 3;
          _busyRadiusKm = (g['busyRadiusKm'] as num?) ?? 2;
        })
        .catchError((_) {});
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    // Rafraîchit les compteurs (« il y a X sec. », attente sur place)
    _clock = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted && (_tab == 1 || t.tick % 15 == 0)) setState(() {});
    });
    final s = Realtime.instance.socket;
    s.on('deliveries:changed', _onChanged);
    s.on('offer:accepted', _onOfferAccepted);
    s.on('offer:rejected', _onOfferRejected);
    s.on('stop:arrived', _onArrived);
    s.on('stop:cancelled', _onStopCancelled);
    s.on('stop:cancel-refused', _onCancelRefused);
    s.on('stop:help-answer', _onHelpAnswer);
    s.on('affiliation:changed', _onAffiliation);
    s.on('stop:retry', _onRetry);
    s.on('stop:return', _onStopReturn);
    s.on('delivery:cancelled', _onDeliveryCancelled);
    s.on('remittance:updated', _onRemittance);
    s.on('delivery:assigned', _onAssigned);
    s.on('delivery:reordered', _onReordered);
    s.on('client:location', _onClientLocation);
    s.on('plan:changed', _onChanged);
    OrderAlert.instance.accepted.addListener(_onAlertAccepted);
    OrderAlert.instance.open.addListener(_onAlertOpen);
    SharedPreferences.getInstance().then((p) {
      if (p.getBool('driver_online') == true) _goOnline();
    });
    // À chaque (re)connexion : les alertes envoyées pendant la coupure sont redemandées
    _offConnect = Realtime.instance.onConnected(_replayAlerts);
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) {
      final s = Realtime.instance.socket;
      if (!s.connected) s.connect();
    });
  }

  /// Nouvelles courses envoyées pendant une coupure (app en arrière-plan, réseau) : alerte + son
  Future<void> _replayAlerts() async {
    if (!_online || api.token == null) return;
    try {
      for (final p in await api.driverAlerts()) {
        if (p is Map) OrderAlert.instance.add(Map<String, dynamic>.from(p));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sheetExtent.dispose();
    _timer?.cancel();
    _clock?.cancel();
    _watchdog?.cancel();
    _offConnect?.call();
    _stopGps();
    final s = Realtime.instance.socket;
    s.off('deliveries:changed', _onChanged);
    s.off('offer:accepted', _onOfferAccepted);
    s.off('offer:rejected', _onOfferRejected);
    s.off('stop:arrived', _onArrived);
    s.off('stop:cancelled', _onStopCancelled);
    s.off('client:location', _onClientLocation);
    s.off('stop:cancel-refused', _onCancelRefused);
    s.off('stop:help-answer', _onHelpAnswer);
    s.off('affiliation:changed', _onAffiliation);
    s.off('stop:retry', _onRetry);
    s.off('stop:return', _onStopReturn);
    s.off('delivery:cancelled', _onDeliveryCancelled);
    s.off('remittance:updated', _onRemittance);
    s.off('delivery:assigned', _onAssigned);
    s.off('delivery:reordered', _onReordered);
    s.off('plan:changed', _onChanged);
    OrderAlert.instance.accepted.removeListener(_onAlertAccepted);
    OrderAlert.instance.open.removeListener(_onAlertOpen);
    super.dispose();
  }

  void _onChanged(dynamic _) => _load();

  /// Course acceptée depuis l'alerte plein écran : elle s'ouvre dans « En cours »
  Future<void> _onAlertAccepted() async {
    final id = OrderAlert.instance.accepted.value;
    if (id == null) return;
    _selectedId = id;
    await _load();
    if (!mounted) return;
    _setTab(1);
    showInfo(
      context,
      _active.length > 1
          ? 'Course acceptée · ${_active.length} courses en cours'
          : 'Course acceptée — direction le départ',
    );
  }

  /// « Voir le détail » depuis l'alerte : fiche de la course (proposer un prix…)
  Future<void> _onAlertOpen() async {
    final id = OrderAlert.instance.open.value;
    if (id == null) return;
    var d = _available.where((x) => x['id'] == id).firstOrNull;
    if (d == null) {
      await _load();
      d = _available.where((x) => x['id'] == id).firstOrNull;
    }
    if (!mounted) return;
    if (d == null) {
      showError(context, 'Cette course n’est plus disponible');
      return;
    }
    _setTab(0);
    _openCourse(d);
  }

  /// L'entreprise a changé l'ordre de passage des arrêts
  Future<void> _onReordered(dynamic _) async {
    await _load();
    if (!mounted) return;
    hapticTap();
    showInfo(context, 'Votre entreprise a changé l’ordre de livraison');
  }

  Future<void> _onOfferAccepted(dynamic _) async {
    await _load();
    if (!mounted) return;
    hapticSuccess();
    _setTab(1);
    showInfo(context, 'Le client a accepté votre prix — direction le départ');
  }

  void _onOfferRejected(dynamic _) {
    _load();
    if (mounted) {
      showInfo(context, 'Le client n’a pas retenu votre proposition');
    }
  }

  void _onArrived(dynamic e) {
    _load();
    if (mounted && e is Map) {
      hapticSuccess();
      showInfo(
        context,
        'Vous êtes chez ${e['recipientName']}. L’expéditeur est prévenu.',
      );
    }
  }

  void _onStopCancelled(dynamic e) {
    _load();
    if (mounted && e is Map) {
      hapticTap();
      showInfo(
        context,
        'Arrêt annulé : ${e['recipientName']} — passez au suivant',
      );
    }
  }

  void _onCancelRefused(dynamic e) {
    _load();
    if (mounted && e is Map) {
      showError(
        context,
        'L’expéditeur maintient la livraison de ${e['recipientName']}',
      );
    }
  }

  /// Réponse de l'expéditeur au livreur sur place (attendre, nouveau numéro…)
  void _onHelpAnswer(dynamic e) {
    _load();
    if (mounted && e is Map) {
      hapticTap();
      showInfo(context, 'Expéditeur · ${e['recipientName']} : ${e['answer']}');
    }
  }

  /// Invitation d'une entreprise, rattachement accepté ou terminé : statut rechargé
  void _onAffiliation(dynamic _) => _load();

  /// L'expéditeur demande une nouvelle tentative après un échec
  void _onRetry(dynamic e) {
    _load();
    if (mounted && e is Map) {
      hapticTap();
      showInfo(
        context,
        'Nouvelle tentative chez ${e['recipientName']} : appelez-le avant d’y retourner',
      );
    }
  }

  void _onStopReturn(dynamic e) {
    _load();
    if (mounted && e is Map) {
      showInfo(
        context,
        'Colis de ${e['recipientName']} à rapporter à l’expéditeur',
      );
    }
  }

  /// Appel depuis l'app : enregistré (preuve d'appel), puis composé
  Future<void> _call(Map d, Map? stop) async {
    final phone =
        (stop == null ? d['pickupPhone'] : stop['recipientPhone']) as String?;
    if (phone == null || phone.isEmpty) return;
    hapticTap();
    unawaited(api.logCall(d['id'], stop?['id']).then((_) => _load()));
    if (!await launchUrl(telUri(phone)) && mounted) {
      showError(
        context,
        'Impossible de lancer l’appel. Numéro : ${formatPhone(phone)}',
      );
    }
  }

  /// Destinataire injoignable sur place : l'expéditeur choisit (attendre, autre numéro, annuler)
  Future<void> _askSender(Map d, Map stop) async {
    if ((stop['callCount'] ?? 0) == 0) {
      showError(
        context,
        'Appelez d’abord ${stop['recipientName']} depuis l’app.',
      );
      return;
    }
    final note = await prompt(
      context,
      'Prévenir l’expéditeur',
      message:
          '${stop['recipientName']} ne répond pas. L’expéditeur va vous dire quoi faire (attendre, autre numéro, annuler).',
      placeholder: 'Facultatif · ex. : portail fermé, 3 appels',
      ok: 'Envoyer',
    );
    if (note == null) return;
    await _run(
      () => api.requestHelp(
        d['id'],
        stop['id'],
        note: note.isEmpty ? null : note,
      ),
      'Expéditeur prévenu · patientez sa réponse',
    );
  }

  void _onDeliveryCancelled(dynamic e) {
    _load();
    if (mounted && e is Map) {
      final fee = (e['fee'] ?? 0) as num;
      showError(
        context,
        fee > 0
            ? 'Course annulée par l’expéditeur · frais de déplacement ${formatMoney(fee, e['currency'])} (récupérés par votre entreprise)'
            : 'Course annulée par l’expéditeur',
      );
    }
  }

  /// Mon entreprise m'affecte une course : elle s'affiche en tête des courses
  Future<void> _onAssigned(dynamic e) async {
    await _load();
    if (!mounted || e is! Map) return;
    hapticSuccess();
    _setTab(0);
    final d = _available.where((x) => x['id'] == e['deliveryId']).firstOrNull;
    showInfo(context, 'Votre entreprise vous affecte une course');
    if (d != null) _openCourse(d);
  }

  void _onRemittance(dynamic e) {
    _load();
    if (!mounted || e is! Map) return;
    if (e['status'] == 'CONFIRMED') {
      hapticSuccess();
      showInfo(context, 'Versement confirmé par votre entreprise');
    } else if (e['status'] == 'REJECTED') {
      showError(
        context,
        'Versement refusé par votre entreprise : voir le motif dans Gains',
      );
    }
  }

  /// Déclarer un versement à l'entreprise
  Future<void> _declareRemittance() async {
    final b = (_cash?['balance'] ?? {}) as Map;
    final max = ((b['toRemit'] ?? 0) as num) - ((b['pending'] ?? 0) as num);
    if (max <= 0) {
      showInfo(context, 'Rien à verser pour le moment');
      return;
    }
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RemittanceSheet(max: max.toInt()),
    );
    if (res == null) return;
    await _run(
      () => api.declareRemittance(
        amount: res['amount'],
        method: res['method'],
        reference: res['reference'],
        proofUrl: res['proofUrl'],
        note: res['note'],
      ),
      'Versement déclaré — votre entreprise le confirme à réception',
    );
  }

  /// Le destinataire annule (il a appelé) : l'expéditeur doit confirmer
  Future<void> _requestCancel(Map d, Map stop) async {
    final note = await pickCancelReason(
      context,
      side: 'driver',
      title: 'Annuler la livraison de ${stop['recipientName']}',
      message:
          'L’expéditeur doit confirmer l’annulation. Sans réponse, elle est acceptée automatiquement. En attendant, continuez vers les autres arrêts.',
      otherPlaceholder: 'Ex. : il a appelé, il ne veut plus du colis',
    );
    if (note == null) return;
    await _run(
      () => api.requestStopCancel(d['id'], stop['id'], note: note),
      'Demande envoyée à l’expéditeur',
    );
  }

  /// Retour des colis non livrés : code de l'expéditeur si l'admin l'exige, sinon au point de départ
  Future<void> _confirmReturn(Map d) async {
    if (!api.returnCodeEnabled) {
      final ok = await showActions<bool>(
        context,
        title: 'Colis rendus à l’expéditeur ?',
        message:
            'Confirmez une fois les colis remis en main propre au point de départ.',
        actions: [('J’ai rendu les colis', true, false)],
      );
      if (ok != true) return;
      await _run(
        () => api.confirmReturn(d['id']),
        'Colis rendus — tournée terminée',
      );
      return;
    }
    final code = await prompt(
      context,
      'Code de retour',
      message:
          'Demandez le code de retour à l’expéditeur en lui remettant ses colis',
      placeholder: '••••',
      keyboard: TextInputType.number,
      large: true,
    );
    if (code == null || code.isEmpty) return;
    await _run(
      () => api.confirmReturn(d['id'], code),
      'Colis rendus — tournée terminée',
    );
  }

  void _setTab(int i) {
    setState(() => _tab = i);
    if (_sheetScroll?.hasClients == true) _sheetScroll!.jumpTo(0);
  }

  /// Retour au premier plan (après Google Maps, un appel…) : connexion et GPS relancés
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    final s = Realtime.instance.socket;
    // iPhone : après quelques secondes en arrière-plan, la connexion peut paraître ouverte alors
    // qu'elle est morte (aucun événement n'arrive) : on la refait à neuf
    if (away.inSeconds >= 10) {
      s.disconnect();
      s.connect();
    } else if (!s.connected) {
      s.connect();
    }
    _replayAlerts();
    if (_online && devPosition == null) {
      _gps?.cancel();
      _gps = _positionStream().listen(_onGps, onError: (_) {});
      myPosition().then((p) {
        if (p != null && mounted) _sendPosition(p);
      });
    }
    _load();
  }

  /// Position partagée par le client d'une course (« Montrer au livreur où je me trouve »)
  final _clientPos = <String, (LatLng, DateTime)>{};

  void _onClientLocation(dynamic e) {
    if (!mounted) return;
    setState(() => _onClientLocationData(e));
  }

  void _onClientLocationData(dynamic e) {
    if (e is! Map || e['deliveryId'] is! String) return;
    if (e['stopped'] == true) {
      _clientPos.remove(e['deliveryId']);
    } else {
      _clientPos[e['deliveryId']] = (
        LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble()),
        DateTime.tryParse(e['at'] ?? '')?.toLocal() ?? DateTime.now(),
      );
    }
  }

  /// Position du client encore fraîche (moins de 2 min), sinon null
  (LatLng, DateTime)? _clientOf(Map? d) {
    final c = d == null ? null : _clientPos[d['id']];
    if (c == null || DateTime.now().difference(c.$2).inSeconds > 120) {
      return null;
    }
    return c;
  }

  /// Ligne « Le client partage sa position » : distance, fraîcheur, itinéraire
  Widget? _clientRow(Map d, Palette p) {
    final c = _clientOf(d);
    if (c == null) return null;
    final ago = DateTime.now().difference(c.$2).inSeconds;
    return GroupRow(
      leading: IconBadge(PhosphorIconsFill.userCircle, color: p.blue),
      title: 'Le client partage sa position',
      subtitle: [
        if (_me != null) 'à ${km(distanceKm(_me!, c.$1))}',
        ago < 10 ? 'en direct' : 'il y a $ago s',
      ].join(' · '),
      trailing: _navButton(c.$1, p),
    );
  }

  Future<void> _load() async {
    // Filet de sécurité si le temps réel est coupé sans le dire : l'alerte arrive à la prochaine actualisation
    _replayAlerts();
    try {
      final r = await Future.wait([
        api.available(),
        api.driverDeliveries(),
        api.myOffers(),
        api.billingStatus().catchError((_) => <String, dynamic>{'ok': true}),
        api.myCash().catchError((_) => <String, dynamic>{}),
        api.driverPlan().catchError((_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        final billing = r[3] as Map<String, dynamic>;
        final cash = r[4] as Map<String, dynamic>;
        if (cash.isNotEmpty) _cash = cash;
        _blocked = billing['ok'] == false ? billing['reason'] as String? : null;
        _available = r[0].cast<Map<String, dynamic>>();
        _mine = r[1].cast<Map<String, dynamic>>();
        _applyPlan(r[5] as Map<String, dynamic>);
        // Alerte d'une course prise entre-temps par un autre livreur : retirée
        OrderAlert.instance.keepOnly(_available.map((d) => d['id'] as String));
        _myOffers = {
          for (final o in r[2].cast<Map<String, dynamic>>())
            o['deliveryId'] as String: o,
        };
        if (_me != null) {
          _available.sort((a, b) => _distanceTo(a).compareTo(_distanceTo(b)));
        }
      });
      // Positions partagées par les clients de mes courses en cours (si l'app a été rouverte)
      if (_active.isNotEmpty) {
        Realtime.instance.socket.emitWithAck(
          'driver:client-locations',
          null,
          ack: (dynamic list) {
            if (!mounted || list is! List) return;
            setState(() {
              for (final e in list) {
                _onClientLocationData(e);
              }
            });
          },
        );
      }
      // Course en cours : suivi en direct hors de l'app (Live Activity / notification fixe)
      DeliveryLive.instance.sync(_current, driver: true, etaMin: _nav.etaMin);
      _refreshActiveRoute();
      _fitTourIfChanged();
      // Course en cours mais GPS éteint (hors ligne) : le suivi démarre tout seul, sinon le client ne voit rien bouger
      if (_active.isNotEmpty && !_online && !_autoTracking) {
        _autoTracking = true;
        _goOnline();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  double _distanceTo(Map d) {
    final p = pointOf(d, 'pickup');
    return (_me == null || p == null) ? double.infinity : distanceKm(_me!, p);
  }

  /// Itinéraire vers la prochaine étape : calculé au changement d'étape, puis suivi à chaque position GPS
  Future<void> _refreshActiveRoute() async {
    final d = _current;
    if (d == null) {
      if (_nav.hasRoute) setState(_nav.clear);
      return;
    }
    final to = _targetOf(d);
    // Sans ma position, l'itinéraire part du départ seulement si je l'ai déjà quitté (colis récupéré)
    final from =
        _me ?? (d['status'] == 'PICKED_UP' ? pointOf(d, 'pickup') : null);
    if (to == null || from == null) return;
    final newTarget = _nav.target == null || distanceM(_nav.target!, to) > 15;
    if (!_nav.update(from, to)) return;
    if (await _nav.fetch(from) && mounted) {
      setState(() {});
      if (newTarget && !_navMode) _fitRoute();
    }
  }

  /// Cadre ma position, la prochaine étape et le trajet restant (au-dessus du panneau)
  /// Tournée affichée en entier (à chaque changement d'étapes : nouvelle course, étape faite, ordre changé)
  String _fittedPlan = '';
  void _fitTourIfChanged() {
    final sig = _plan.join(',');
    if (sig == _fittedPlan || _navMode) return;
    _fittedPlan = sig;
    final pts = _tourPoints().map((t) => t.point).toList();
    if (pts.length < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      fitPoints(
        _map,
        [?_me, ...pts],
        // Marges : boutons de la carte en haut, panneau en bas
        padding: EdgeInsets.fromLTRB(
          70,
          190,
          90,
          MediaQuery.of(context).size.height * _sheetExtent.value + 20,
        ),
      );
    });
  }

  void _fitRoute() {
    if (_tourPoints().length > 1) {
      _fittedPlan = '';
      return _fitTourIfChanged();
    }
    final d = _current;
    final to = d == null ? null : _targetOf(d);
    final from = _me ?? (d == null ? null : pointOf(d, 'pickup'));
    if (from == null || to == null) return;
    fitPoints(
      _map,
      [from, to, ..._nav.remaining],
      padding: EdgeInsets.fromLTRB(
        50,
        110,
        50,
        MediaQuery.of(context).size.height * _sheetExtent.value + 20,
      ),
    );
  }

  /// Flux GPS du livreur : une position toutes les 1 à 2 s en mouvement (seuil 3 m)
  Stream<Position> _positionStream() => Geolocator.getPositionStream(
    locationSettings: Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 3,
            allowBackgroundLocationUpdates: true,
            showBackgroundLocationIndicator: true,
            pauseLocationUpdatesAutomatically: false,
            activityType: ActivityType.otherNavigation,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3,
            intervalDuration: const Duration(seconds: 2),
          ),
  );

  void _toggleNav() {
    hapticTap();
    setState(() => _navMode = !_navMode);
    if (_navMode) {
      _followMe();
    } else {
      _map.rotate(0);
      _fitRoute();
    }
  }

  /// Mode navigation : centré sur moi (dans la partie visible), carte orientée vers ma direction
  void _followMe() {
    final me = _shownMe;
    if (!_navMode || me == null) return;
    final h = MediaQuery.of(context).size.height;
    _map.rotate(_hasHeading ? -_headingDeg : 0);
    _map.move(me, 17, offset: Offset(0, -h * _sheetExtent.value / 2 + 40));
  }

  /// Ma position affichée : recalée sur l'itinéraire si je suis dessus
  LatLng? get _shownMe {
    final f = _nav.fix;
    if (_me == null) return null;
    return _nav.hasRoute && f != null && f.offRouteM < 30 ? f.snapped : _me;
  }

  // ---------- En ligne / Hors ligne ----------

  Future<void> _goOnline() async {
    final first = await myPosition();
    if (!mounted) return;
    if (first == null) {
      showError(context, 'Activez la localisation pour passer en ligne.');
      return;
    }
    hapticSuccess();
    setState(() => _online = true);
    (await SharedPreferences.getInstance()).setBool('driver_online', true);
    _sendPosition(first);
    _map.move(first, 14);
    // L'app reste connectée en arrière-plan pour recevoir les courses (notifications + sons)
    LetoNotifier.instance.startKeepAlive(driver: true);
    if (devPosition == null) {
      // Suivi pro : une position toutes les 1 à 2 s en mouvement (3 m de seuil), cap et vitesse inclus
      _gps = _positionStream().listen(_onGps, onError: (_) {});
    }
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_me != null) _sendPosition(_me!);
    });
    _load();
  }

  Future<void> _goOffline() async {
    if (_active.isNotEmpty) {
      showError(context, 'Terminez votre course avant de passer hors ligne.');
      return;
    }
    _stopGps();
    LetoNotifier.instance.stopKeepAlive();
    Realtime.instance.socket.emit('driver:offline');
    setState(() => _online = false);
    (await SharedPreferences.getInstance()).setBool('driver_online', false);
  }

  void _stopGps() {
    _gps?.cancel();
    _gps = null;
    _heartbeat?.cancel();
  }

  DateTime _lastSent = DateTime(2000);

  /// Point GPS : ignore les mesures imprécises, limite l'envoi à une position par seconde
  void _onGps(Position p) {
    if (p.accuracy > 60) return;
    final now = DateTime.now();
    if (now.difference(_lastSent).inMilliseconds < 900) return;
    _sendPosition(
      LatLng(p.latitude, p.longitude),
      // Le cap GPS n'a de sens qu'en mouvement (> 1 m/s ≈ 4 km/h)
      heading: p.speed > 1 && p.heading >= 0 ? p.heading : null,
      speed: p.speed >= 0 ? p.speed : null,
    );
  }

  void _sendPosition(LatLng p, {double? heading, double? speed}) {
    _lastSent = DateTime.now();
    if (heading != null) {
      // Rotation par le plus court chemin (pas de tour complet entre 359° et 1°)
      var delta = heading / 360 - (_headingTurns % 1);
      if (delta > 0.5) delta -= 1;
      if (delta < -0.5) delta += 1;
      _headingTurns += delta;
      _headingDeg = heading;
      _hasHeading = true;
    }
    if (mounted) setState(() => _me = p);
    // Itinéraire en direct : position recalée, reste du trajet, recalcul si je dévie
    final d = _current;
    final to = d == null ? null : _targetOf(d);
    if (to != null && _nav.update(p, to)) {
      _nav.fetch(p).then((ok) {
        if (ok && mounted) setState(() {});
      });
    }
    _followMe();
    Realtime.instance.socket.emit('driver:location', {
      'lat': p.latitude,
      'lng': p.longitude,
      'heading': ?heading,
      'speed': ?speed,
    });
  }

  // ---------- Actions ----------

  Future<void> _openCourse(Map<String, dynamic> d) async {
    final result = await showCourseSheet(
      context,
      d,
      _me,
      myOffer: _myOffers[d['id']],
    );
    await _load();
    if (!mounted) return;
    if (result == 'accepted') {
      _selectedId = d['id'] as String?;
      _setTab(1);
      showInfo(context, 'Course acceptée — direction le départ');
    } else if (result == 'offered') {
      showInfo(context, 'Proposition envoyée — en attente du client');
    }
  }

  Future<void> _run(Future<dynamic> Function() action, String success) async {
    try {
      await action();
      hapticSuccess();
      if (mounted) showInfo(context, success);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    await _load();
    // Affiche l'étape suivante en haut du panneau
    if (_sheetScroll?.hasClients == true) _sheetScroll!.jumpTo(0);
  }

  Future<void> _deliver(Map d, Map stop) async {
    final cod = (stop['codAmount'] ?? 0) as num;
    if (cod > 0 &&
        !await confirm(
          context,
          'Encaissement',
          message:
              'Avez-vous encaissé ${formatMoney(cod, d['currency'])} auprès de ${stop['recipientName']} ?',
          ok: 'Oui, encaissé',
        )) {
      return;
    }
    if (!mounted) return;
    // Confirmation par code désactivée par l'admin : le livreur valide seul
    if (!api.deliveryCodeEnabled) {
      if (!await confirm(
        context,
        'Colis remis à ${stop['recipientName']} ?',
        ok: 'Oui, livré',
      )) {
        return;
      }
      await _run(
        () => api.deliverStop(d['id'], stop['id'], ''),
        'Colis livré à ${stop['recipientName']}',
      );
      return;
    }
    if (!mounted) return;
    final code = await prompt(
      context,
      'Code de livraison',
      message: 'Demandez le code à ${stop['recipientName']}',
      placeholder: '••••',
      keyboard: TextInputType.number,
      large: true,
    );
    if (code == null || code.isEmpty) return;
    await _run(
      () => api.deliverStop(d['id'], stop['id'], code),
      'Colis livré à ${stop['recipientName']}',
    );
  }

  /// Secondes d'attente restantes avant de pouvoir signaler une absence (null = arrivée non détectée)
  int? _waitLeft(Map stop) {
    if (stop['arrivedAt'] == null) return null;
    final waited = DateTime.now()
        .difference(DateTime.parse(stop['arrivedAt']))
        .inSeconds;
    return (_absenceWaitMin * 60 - waited).clamp(0, 99999);
  }

  /// Échec : sur place, attente (absence), photo obligatoire. L'expéditeur est prévenu.
  Future<void> _reportProblem(Map d, Map stop) async {
    final cod = ((stop['codAmount'] ?? 0) as num) > 0;
    final reason = await showActions<String>(
      context,
      title: 'Problème avec ${stop['recipientName']}',
      message:
          'Appelez d’abord le destinataire : ${formatPhone(stop['recipientPhone'])}',
      actions: [
        ('Destinataire absent ou injoignable', 'ABSENT', false),
        ('Adresse introuvable', 'WRONG_ADDRESS', false),
        ('Le destinataire refuse le colis', 'REFUSED', true),
        if (cod) ('Il n’a pas l’argent pour payer', 'NO_MONEY', false),
        ('Colis abîmé', 'DAMAGED', false),
        ('Lieu dangereux ou inaccessible', 'UNSAFE', false),
        if (stop['cancelRequestedAt'] == null)
          ('Le destinataire annule (il a appelé)', 'CANCEL', false),
      ],
    );
    if (reason == null || !mounted) return;
    if (reason == 'CANCEL') return _requestCancel(d, stop);
    if ((reason == 'ABSENT' || reason == 'WRONG_ADDRESS') &&
        (stop['callCount'] ?? 0) == 0) {
      showError(
        context,
        'Appelez d’abord ${stop['recipientName']} depuis l’app.',
      );
      return;
    }
    final waitUntil = DateTime.tryParse(stop['waitUntil'] ?? '');
    if (reason == 'ABSENT' &&
        waitUntil != null &&
        waitUntil.isAfter(DateTime.now())) {
      showError(
        context,
        'L’expéditeur vous demande de patienter encore ${_fmt(waitUntil.difference(DateTime.now()).inSeconds)}.',
      );
      return;
    }
    if (reason == 'ABSENT') {
      final left = _waitLeft(stop);
      if (left == null) {
        showError(
          context,
          'Arrivée non détectée : rapprochez-vous de l’adresse (moins de 150 m).',
        );
        return;
      }
      if (left > 0) {
        showError(
          context,
          'Patientez encore ${_fmt(left)} et essayez d’appeler le destinataire.',
        );
        return;
      }
    }
    // Photo obligatoire du lieu (appareil photo ; photothèque autorisée en développement)
    String? url = _devPhoto.isEmpty ? null : _devPhoto;
    if (url == null) {
      final source = kDebugMode
          ? await showActions<ImageSource>(
              context,
              title: 'Photo du lieu (obligatoire)',
              actions: [
                ('Prendre une photo', ImageSource.camera, false),
                ('Photothèque (développement)', ImageSource.gallery, false),
              ],
            )
          : ImageSource.camera;
      if (source == null) return;
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        imageQuality: 70,
      );
      if (file == null) return;
      try {
        url = await api.upload(File(file.path));
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
    }
    if (!mounted) return;
    final note = await prompt(
      context,
      'Commentaire',
      message: 'Facultatif — visible par l’expéditeur',
      placeholder: 'Ex. : portail fermé, 3 appels',
      ok: 'Envoyer',
    );
    if (note == null) return;
    final photo = url;
    await _run(
      () => api.failStop(
        d['id'],
        stop['id'],
        reason: reason,
        photoUrl: photo,
        note: note.isEmpty ? null : note,
      ),
      (stop['attempt'] ?? 1) > 1 || reason == 'DAMAGED'
          ? 'Échec signalé · rapportez le colis à l’expéditeur'
          : 'Échec signalé · l’expéditeur choisit : nouvelle tentative ou retour',
    );
  }

  /// Délai restant à l'expéditeur pour choisir (sinon retour automatique)
  String _deadlineText(Map s) {
    final end = DateTime.tryParse(s['followUpDeadline'] ?? '');
    if (end == null) return followUpLabels['DECIDING']!;
    final left = end.difference(DateTime.now()).inSeconds;
    return left > 0
        ? 'Choix de l’expéditeur · retour automatique dans ${_fmt(left)}'
        : 'Retour automatique imminent';
  }

  String _fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final active = _current;
    final target = active == null ? null : _targetOf(active);
    // Plusieurs étapes : la carte montre toute la tournée, numérotée dans l'ordre de passage
    final tour = _tourPoints();
    final tourMode = tour.length > 1;

    return Scaffold(
      backgroundColor: p.background,
      body: Stack(
        children: [
          LetoMap(
            controller: _map,
            // Je déplace la carte moi-même : le mode navigation s'arrête
            onMove: (_, gesture) {
              if (gesture && _navMode) {
                setState(() => _navMode = false);
                _map.rotate(0);
              }
            },
            layers: [
              // Ordre de la tournée : pointillés de ma position à la dernière étape
              if (tourMode)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [?_shownMe, ...tour.map((t) => t.point)],
                      strokeWidth: 3,
                      color: p.secondaryLabel.withValues(alpha: 0.55),
                      pattern: StrokePattern.dashed(segments: const [8, 7]),
                    ),
                  ],
                ),
              if (active != null && _nav.hasRoute)
                routeLayer(
                  _nav.remaining,
                  color: active['status'] == 'ACCEPTED' ? p.blue : p.green,
                ),
              MarkerLayer(
                markers: [
                  if (active == null && _online)
                    for (final d in _available)
                      Marker(
                        point: pointOf(d, 'pickup')!,
                        width: 96,
                        height: 36,
                        child: GestureDetector(
                          onTap: () => _openCourse(d),
                          child: _PriceTag(
                            d['price'],
                            currency: d['currency'],
                            stops: _stopsOf(d).length,
                          ),
                        ),
                      ),
                  if (tourMode)
                    for (final (i, t) in tour.indexed.toList().reversed)
                      Marker(
                        key: Key('tour-pin-$i'),
                        point: t.point,
                        width: i == 0 ? 44 : 34,
                        height: i == 0 ? 44 : 34,
                        child: GestureDetector(
                          onTap: () {
                            hapticTap();
                            setState(() => _selectedId = t.courseId);
                            _setTab(1);
                            _refreshActiveRoute();
                          },
                          child: _TourPin(
                            number: i + 1,
                            color: t.color,
                            icon: t.icon,
                            next: i == 0,
                            faded: t.courseId != active?['id'],
                          ),
                        ),
                      ),
                  if (active != null && !tourMode)
                    for (final s in _stopsOf(active))
                      stopMarker(
                        context,
                        _pt(s),
                        s['position'] + 1,
                        status: s['status'],
                      ),
                  if (active != null &&
                      !tourMode &&
                      active['status'] == 'ACCEPTED' &&
                      target != null)
                    pickupMarker(target),
                  if (_clientOf(active) case final c?) clientMarker(c.$1),
                  // Moi : flèche orientée dans mon sens de marche pendant une course, point sinon
                  if (_shownMe != null)
                    active != null
                        ? driverMarker(
                            _shownMe!,
                            vehicle: api.user?['vehicleType'],
                            headingTurns: _hasHeading ? _headingTurns : null,
                          )
                        : myMarker(_shownMe!),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      MapButton(
                        PhosphorIconsBold.userCircle,
                        onTap: () => showAccountSheet(
                          context,
                          items: [
                            if (api.isIndependent) ...[
                              (
                                PhosphorIconsFill.creditCard,
                                p.green,
                                'Mon solde',
                                () => Navigator.push(
                                  context,
                                  CupertinoPageRoute(
                                    builder: (_) =>
                                        const IndependentBalanceScreen(),
                                  ),
                                ),
                              ),
                              (
                                PhosphorIconsFill.buildings,
                                accent,
                                'Mon entreprise',
                                () => Navigator.push(
                                  context,
                                  CupertinoPageRoute(
                                    builder: (_) => const AffiliationScreen(),
                                  ),
                                ),
                              ),
                              (
                                PhosphorIconsFill.files,
                                accent,
                                'Mes documents',
                                () => Navigator.push(
                                  context,
                                  CupertinoPageRoute(
                                    builder: (_) => const DocumentsScreen(),
                                  ),
                                ),
                              ),
                              (
                                PhosphorIconsFill.identificationCard,
                                accent,
                                'Mon dossier',
                                () async {
                                  final d = await api.myDossier();
                                  if (!context.mounted) return;
                                  Navigator.push(
                                    context,
                                    CupertinoPageRoute(
                                      builder: (_) => DossierScreen(initial: d),
                                    ),
                                  );
                                },
                              ),
                            ],
                            if (!api.isIndependent)
                              (
                                PhosphorIconsFill.wallet,
                                p.green,
                                'Ma paye',
                                () => Navigator.push(
                                  context,
                                  CupertinoPageRoute(
                                    builder: (_) => const PayrollScreen(),
                                  ),
                                ),
                              ),
                            (
                              PhosphorIconsFill.clock,
                              p.blue,
                              'Historique',
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      HistoryScreen(load: api.driverDeliveries),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      _StatusPill(
                        online: _online,
                        onChanged: (v) => v ? _goOnline() : _goOffline(),
                      ),
                      const Spacer(),
                      MapButton(
                        PhosphorIconsFill.navigationArrow,
                        onTap: () =>
                            _me != null ? _map.move(_me!, 15) : _goOnline(),
                      ),
                    ],
                  ),
                  AnimatedSwitcher(
                    duration: Motion.medium,
                    child: _blocked == null
                        ? const SizedBox.shrink()
                        : Padding(
                            key: ValueKey(_blocked),
                            padding: const EdgeInsets.only(top: 10),
                            child: GestureDetector(
                              // Indépendant : le bandeau mène à « Mes documents » (expiré), « Mon entreprise » (rattachement) ou au solde (recharge)
                              onTap: api.isIndependent
                                  ? () => Navigator.push(
                                      context,
                                      CupertinoPageRoute(
                                        builder: (_) =>
                                            _blocked!.contains('Mes documents')
                                            ? const DocumentsScreen()
                                            : _blocked!.contains('Rattachez')
                                            ? const AffiliationScreen()
                                            : const IndependentBalanceScreen(),
                                      ),
                                    )
                                  : null,
                              child: _BlockedBanner(_blocked!),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          // Navigation : la carte me suit, orientée dans mon sens de marche
          if (active != null && _me != null)
            ValueListenableBuilder<double>(
              valueListenable: _sheetExtent,
              builder: (_, extent, child) => Positioned(
                right: 12,
                bottom: MediaQuery.of(context).size.height * extent + 12,
                child: AnimatedOpacity(
                  opacity: extent > 0.75 ? 0 : 1,
                  duration: Motion.fast,
                  child: child,
                ),
              ),
              child: Semantics(
                label: _navMode
                    ? 'Quitter le mode navigation'
                    : 'Mode navigation',
                child: MapButton(
                  _navMode
                      ? PhosphorIconsFill.navigationArrow
                      : PhosphorIconsBold.navigationArrow,
                  onTap: _toggleNav,
                ),
              ),
            ),
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) {
              _sheetExtent.value = n.extent;
              return false;
            },
            child: DraggableScrollableSheet(
              initialChildSize: 0.5,
              minChildSize: 0.18,
              maxChildSize: 0.92,
              snap: true,
              snapSizes: const [0.5],
              builder: (context, scroll) {
                _sheetScroll = scroll;
                return ClipRSuperellipse(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  child: Container(
                    color: p.background,
                    child: CustomScrollView(
                      controller: scroll,
                      slivers: [
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _SheetHeader(
                            color: p.background,
                            child: CupertinoSlidingSegmentedControl<int>(
                              groupValue: _tab,
                              onValueChanged: (i) {
                                hapticTap();
                                _setTab(i ?? 0);
                              },
                              children: {
                                0: _seg(
                                  'Courses${_online && _available.isNotEmpty ? ' (${_available.length})' : ''}',
                                ),
                                1: _seg(
                                  'En cours${_active.isNotEmpty ? ' (${_active.length})' : ''}',
                                ),
                                2: _seg('Gains'),
                                3: _seg('Carnet'),
                              },
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.only(bottom: 32),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate(switch (_tab) {
                              0 => _ordersTab(p),
                              1 => _activeTab(p),
                              3 => [const DriverLogbook()],
                              _ => _gainsTab(p),
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _seg(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Text(label, style: TextStyles.subheadline),
  );

  Widget _title(String text, Palette p, {String? subtitle}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: TextStyles.title1.copyWith(color: p.label)),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(
            subtitle,
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
      ],
    ),
  );

  // ----- Courses -----
  List<Widget> _ordersTab(Palette p) {
    if (!_online) {
      return [
        _title(
          'Hors ligne',
          p,
          subtitle: 'Passez en ligne pour recevoir les courses autour de vous.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _goOnline,
            icon: const Icon(PhosphorIconsBold.power),
            label: const Text('Passer en ligne'),
          ),
        ),
      ];
    }
    return [
      _title(
        'Courses disponibles',
        p,
        subtitle: _active.length >= _maxActive
            ? 'Vous avez $_maxActive courses en cours (le maximum) : terminez-en une pour en accepter d’autres.'
            : _active.isNotEmpty
            ? 'Pendant votre course : celles sur votre trajet ou à moins de ${km(_busyRadiusKm)} de vous.'
            : _available.isEmpty
            ? 'Aucune course pour le moment. Elles arrivent en temps réel.'
            : 'En temps réel · les plus proches d’abord',
      ),
      for (final d in _available)
        _OrderCard(
          d: d,
          distance: _me == null ? null : _distanceTo(d),
          myOffer: _myOffers[d['id']],
          match: d['match'] as Map?,
          onTap: () => _openCourse(d),
        ),
    ];
  }

  // ----- En cours -----
  /// Toutes les courses en cours : sélecteur au-dessus du détail de la course choisie
  List<Widget> _activeTab(Palette p) => [
    if (_plan.where((k) => _taskInfo(k, p) != null).length > 1) _tour(p),
    ..._activeDetail(p),
  ];

  // ----- Tournée -----
  void _applyPlan(Map<String, dynamic> res) {
    if (res['keys'] is! List) return;
    _plan = (res['keys'] as List).cast<String>();
    _planKm = res['km'] as num?;
    _planBestKm = res['optimizedKm'] as num?;
  }

  /// Course d'une étape (clé P:/R: = course, S: = arrêt d'une course)
  String? _courseOfKey(String k) {
    final id = k.substring(2);
    if (k.startsWith('S:')) {
      for (final d in _active) {
        if (_stopsOf(d).any((s) => s['id'] == id)) return d['id'] as String;
      }
      return null;
    }
    return id;
  }

  /// Règles : récupérer avant de livrer, rapporter après le dernier arrêt (null si l'ordre est valable)
  String? _planError(List<String> keys) {
    final seen = <String>{};
    for (final k in keys) {
      final course = _courseOfKey(k);
      if (!k.startsWith('P:') &&
          keys.contains('P:$course') &&
          !seen.contains('P:$course')) {
        return 'Récupérez les colis avant de les livrer';
      }
      if (k.startsWith('R:') &&
          keys.any(
            (o) =>
                o.startsWith('S:') &&
                _courseOfKey(o) == course &&
                !seen.contains(o),
          )) {
        return 'Le retour des colis vient après le dernier arrêt';
      }
      seen.add(k);
    }
    return null;
  }

  /// Enregistre le nouvel ordre (affiché tout de suite, annulé si le serveur le refuse)
  Future<void> _savePlan(List<String> keys, {String? done}) async {
    final err = _planError(keys);
    if (err != null) {
      showError(context, err);
      return;
    }
    final before = _plan;
    hapticTap();
    setState(() {
      _plan = keys;
      _selectedId = null;
    });
    try {
      final res = await api.saveDriverPlan(keys);
      if (!mounted) return;
      setState(() => _applyPlan(res));
      if (done != null) showInfo(context, done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _plan = before);
      showError(context, e);
    }
    await _load();
  }

  /// Étapes liées : le départ d'une course entraîne ses arrêts et son retour
  List<String> _withDependents(String key) {
    if (!key.startsWith('P:')) return [key];
    final course = key.substring(2);
    return _plan.where((k) => k == key || _courseOfKey(k) == course).toList();
  }

  /// « Faire maintenant » : l'étape (et son départ s'il n'est pas fait) passe en tête
  void _doNow(String key) {
    final course = _courseOfKey(key);
    final head = [
      if (!key.startsWith('P:') && _plan.contains('P:$course')) 'P:$course',
      key,
    ];
    _savePlan([
      ...head,
      ..._plan.where((k) => !head.contains(k)),
    ], done: 'Étape placée en premier');
  }

  /// « Plus tard » : l'étape (et ce qui en dépend) passe en fin de tournée — destinataire indisponible…
  void _later(String key) {
    final tail = _withDependents(key);
    _savePlan([
      ..._plan.where((k) => !tail.contains(k)),
      ...tail,
    ], done: 'Étape repoussée en fin de tournée');
  }

  Future<void> _optimizePlan() async {
    hapticTap();
    try {
      final res = await api.optimizeDriverPlan();
      if (!mounted) return;
      setState(() {
        _applyPlan(res);
        _selectedId = null;
      });
      showInfo(context, 'Tournée optimisée · ${km(res['km'] ?? 0)}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    await _load();
  }

  /// Une étape de la tournée : ce qu'il faut faire, où, pour quelle course
  ({String title, String subtitle, IconData icon, Color color})? _taskInfo(
    String key,
    Palette p,
  ) {
    final course = _courseOfKey(key);
    final d = _active.where((x) => x['id'] == course).firstOrNull;
    if (d == null) return null;
    final price = formatMoney(d['price'], d['currency']);
    if (key.startsWith('P:')) {
      final sender =
          (d['pickupContactName'] ?? d['client']?['name'] ?? '') as String;
      return (
        title: 'Récupérer · ${d['pickupCommune'] ?? d['pickupAddress']}',
        subtitle: [if (sender.isNotEmpty) sender, price].join(' · '),
        icon: PhosphorIconsFill.arrowCircleUp,
        color: ink,
      );
    }
    if (key.startsWith('R:')) {
      return (
        title: 'Rapporter les colis · ${d['pickupCommune'] ?? ''}',
        subtitle: 'Retour à l’expéditeur · $price',
        icon: PhosphorIconsFill.arrowUDownLeft,
        color: p.yellow,
      );
    }
    final stop = _stopsOf(
      d,
    ).where((s) => s['id'] == key.substring(2)).firstOrNull;
    if (stop == null) return null;
    return (
      title: 'Livrer ${stop['recipientName']}',
      subtitle: [
        stop['commune'] ?? stop['address'],
        price,
      ].whereType<String>().join(' · '),
      icon: PhosphorIconsFill.package,
      color: p.red,
    );
  }

  /// Étapes de la tournée à placer sur la carte, dans l'ordre de passage
  List<({LatLng point, String courseId, Color color, IconData icon})>
  _tourPoints() {
    final p = Palette.of(context);
    final out =
        <({LatLng point, String courseId, Color color, IconData icon})>[];
    for (final k in _plan) {
      final course = _courseOfKey(k);
      final d = _active.where((x) => x['id'] == course).firstOrNull;
      if (d == null) continue;
      LatLng? pt;
      if (k.startsWith('S:')) {
        final stop = _stopsOf(
          d,
        ).where((s) => s['id'] == k.substring(2)).firstOrNull;
        if (stop != null) pt = _pt(stop);
      } else {
        pt = pointOf(d, 'pickup');
      }
      if (pt == null) continue;
      out.add((
        point: pt,
        courseId: course!,
        color: k.startsWith('P:')
            ? ink
            : k.startsWith('R:')
            ? p.yellow
            : accent,
        icon: k.startsWith('P:')
            ? PhosphorIconsBold.arrowUp
            : k.startsWith('R:')
            ? PhosphorIconsBold.arrowUDownLeft
            : PhosphorIconsFill.package,
      ));
    }
    return out;
  }

  /// « Ma tournée » : toutes les étapes dans l'ordre, à réorganiser (glisser, Faire maintenant, Plus tard)
  Widget _tour(Palette p) {
    final keys = _plan.where((k) => _taskInfo(k, p) != null).toList();
    final cur = _current?['id'];
    final accent = Theme.of(context).colorScheme.primary;
    final canOptimize =
        _planKm != null &&
        _planBestKm != null &&
        _planKm! - _planBestKm! >= 0.3;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ma tournée',
                        style: TextStyles.title3.copyWith(color: p.label),
                      ),
                      Text(
                        [
                          '${keys.length} étapes',
                          if (_active.length > 1) '${_active.length} courses',
                          if (_planKm != null) km(_planKm!),
                        ].join(' · '),
                        style: TextStyles.footnote.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canOptimize)
                  TextButton.icon(
                    key: const Key('plan-optimize'),
                    onPressed: _optimizePlan,
                    icon: const Icon(PhosphorIconsBold.magicWand, size: 18),
                    label: Text('Optimiser (−${km(_planKm! - _planBestKm!)})'),
                  ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: ReorderableListView.builder(
              key: const Key('plan-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: keys.length,
              proxyDecorator: (child, _, _) => Material(
                elevation: 6,
                color: p.card,
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
              onReorder: (from, to) {
                final next = [...keys];
                final k = next.removeAt(from);
                next.insert(to > from ? to - 1 : to, k);
                _savePlan(next);
              },
              itemBuilder: (_, i) {
                final k = keys[i];
                final t = _taskInfo(k, p)!;
                final on = _courseOfKey(k) == cur;
                return Material(
                  key: ValueKey(k),
                  color: on ? accent.withValues(alpha: 0.08) : p.card,
                  child: InkWell(
                    onTap: () {
                      hapticTap();
                      setState(() => _selectedId = _courseOfKey(k));
                      _refreshActiveRoute();
                    },
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                      decoration: BoxDecoration(
                        border: i == keys.length - 1
                            ? null
                            : Border(
                                bottom: BorderSide(
                                  color: p.separator,
                                  width: 0.5,
                                ),
                              ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: i == 0 ? accent : p.fill,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                color: i == 0 ? Colors.white : p.label,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Icon(t.icon, color: t.color, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyles.subheadline.copyWith(
                                    color: p.label,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  t.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyles.footnote.copyWith(
                                    color: p.secondaryLabel,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            key: Key('plan-menu-$i'),
                            icon: Icon(
                              PhosphorIconsBold.dotsThree,
                              color: p.secondaryLabel,
                              size: 20,
                            ),
                            onSelected: (a) =>
                                a == 'now' ? _doNow(k) : _later(k),
                            itemBuilder: (_) => [
                              if (i > 0)
                                const PopupMenuItem(
                                  value: 'now',
                                  child: Text('Faire maintenant'),
                                ),
                              if (i < keys.length - 1)
                                const PopupMenuItem(
                                  value: 'later',
                                  child: Text('Plus tard (en fin de tournée)'),
                                ),
                            ],
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Icon(
                                PhosphorIconsBold.list,
                                color: p.tertiaryLabel,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Text(
              'Maintenez la poignée à droite et glissez pour changer l’ordre. Destinataire indisponible ? « Plus tard » : livrez ailleurs et revenez.',
              style: TextStyles.caption.copyWith(color: p.tertiaryLabel),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _activeDetail(Palette p) {
    final d = _current;
    if (d == null) {
      return [
        _title(
          'Aucune course en cours',
          p,
          subtitle:
              'Acceptez une course ou proposez votre prix dans « Courses ».',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TintedButton(
            'Voir les courses',
            icon: PhosphorIconsBold.listBullets,
            onPressed: () => _setTab(0),
          ),
        ),
      ];
    }
    final stops = _stopsOf(d);
    final n = stops.length;
    final done = stops.where((s) => s['status'] != 'PENDING').length;
    final routeInfo = !_nav.hasRoute
        ? null
        : '${_nav.etaMin} min · ${km((_nav.remainingM ?? 0) / 1000)}';

    // Étape 1 : récupérer les colis
    if (d['status'] == 'ACCEPTED') {
      final sender =
          (d['pickupContactName'] ?? d['client']?['name'] ?? '') as String;
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: StatusSteps(d['status']),
        ),
        _title('Vers le départ', p, subtitle: routeInfo),
        InsetGroup(
          children: [
            GroupRow(
              leading: _dot('A', ink),
              title: '${d['pickupAddress']} (${d['pickupCommune']})',
              subtitle: d['pickupDetails'],
              trailing: _navButton(pointOf(d, 'pickup'), p),
            ),
            GroupRow(
              leading: Avatar(sender, radius: 15),
              title: sender,
              subtitle: 'Expéditeur',
              trailing: _phone(d['pickupPhone'], p, () => _call(d, null)),
            ),
            ?_clientRow(d, p),
            if (d['pickupPhotoUrl'] != null)
              GroupRow(
                leading: AddressPhoto(d['pickupPhotoUrl'], size: 44),
                title: 'Photo du lieu',
              ),
            if ((d['courierComment'] ?? '').toString().isNotEmpty)
              GroupRow(
                leading: Icon(
                  PhosphorIconsBold.chatText,
                  color: p.secondaryLabel,
                  size: 20,
                ),
                title: d['courierComment'],
              ),
          ],
        ),
        // Avant de prendre la route : appeler l'expéditeur et chaque destinataire
        InsetGroup(
          header: 'Avant de prendre la route',
          footer: api.preCallRequired
              ? 'Appelez chaque destinataire pour confirmer qu’il est disponible et lui donner l’heure de passage. Obligatoire avant de partir avec les colis.'
              : 'Appelez chaque destinataire pour confirmer qu’il est disponible et lui donner l’heure de passage.',
          children: [
            GroupRow(
              leading: _calledBadge(d['pickupCalledAt'] != null, p),
              title: 'Expéditeur · colis prêt ?',
              subtitle: sender,
              trailing: _phone(d['pickupPhone'], p, () => _call(d, null)),
            ),
            for (final s in stops.where((s) => s['status'] == 'PENDING'))
              GroupRow(
                leading: _calledBadge(s['calledAt'] != null, p),
                title: s['recipientName'],
                subtitle: '${s['address']} (${s['commune']})',
                trailing: _phone(s['recipientPhone'], p, () => _call(d, s)),
              ),
          ],
        ),
        Builder(
          builder: (_) {
            final missing = stops
                .where((s) => s['status'] == 'PENDING' && s['calledAt'] == null)
                .length;
            final blocked = api.preCallRequired && missing > 0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: blocked
                    ? null
                    : () => _run(
                        () => api.pickup(d['id']),
                        n > 1
                            ? 'Colis récupérés — début de la tournée'
                            : 'Colis récupéré',
                      ),
                child: Text(
                  blocked
                      ? (missing == 1
                            ? 'Appelez le destinataire pour continuer'
                            : 'Appelez les $missing destinataires pour continuer')
                      : n > 1
                      ? 'J’ai récupéré les $n colis'
                      : 'J’ai récupéré le colis',
                ),
              ),
            );
          },
        ),
      ];
    }

    // Étape 3 : retour des colis non livrés à l'expéditeur
    if (_returning(d)) {
      final back = stops.where((s) => s['status'] != 'DELIVERED').toList();
      final sender =
          (d['pickupContactName'] ?? d['client']?['name'] ?? '') as String;
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: StatusSteps(d['status']),
        ),
        _title(
          'Retour à l’expéditeur',
          p,
          subtitle: ['${back.length} colis à rendre', ?routeInfo].join(' · '),
        ),
        InsetGroup(
          footer: api.returnCodeEnabled
              ? 'Remettez les colis à l’expéditeur : il vous donne son code de retour pour terminer la tournée.'
              : 'Remettez les colis à l’expéditeur au point de départ, puis confirmez pour terminer la tournée.',
          children: [
            GroupRow(
              leading: _dot('A', ink),
              title: '${d['pickupAddress']} (${d['pickupCommune']})',
              trailing: _navButton(pointOf(d, 'pickup'), p),
            ),
            GroupRow(
              leading: Avatar(sender, radius: 15),
              title: sender,
              subtitle: 'Expéditeur',
              trailing: _phone(d['pickupPhone'], p, () => _call(d, null)),
            ),
            ?_clientRow(d, p),
            for (final s in back)
              GroupRow(
                leading: Icon(
                  PhosphorIconsBold.package,
                  color: p.secondaryLabel,
                  size: 20,
                ),
                title: s['recipientName'],
                value: s['status'] == 'FAILED'
                    ? failureLabels[s['failureReason']]
                    : stopStatusLabels[s['status']],
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton(
            onPressed: () => _confirmReturn(d),
            child: Text(
              api.returnCodeEnabled
                  ? 'Saisir le code de retour'
                  : 'J’ai rendu les colis',
            ),
          ),
        ),
      ];
    }

    // Étape 2 : tournée, arrêt par arrêt
    final next = _nextStop(d);
    final deciding = stops
        .where((s) => s['status'] == 'FAILED' && s['followUp'] == 'DECIDING')
        .toList();
    final list = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: StatusSteps(d['status']),
      ),
      _title(
        next == null && deciding.isNotEmpty
            ? 'En attente de l’expéditeur'
            : next == null
            ? 'Tournée terminée'
            : (n > 1
                  ? 'Arrêt ${next['position'] + 1} sur $n'
                  : 'Vers le destinataire'),
        p,
        subtitle: [if (n > 1) '$done/$n traités', ?routeInfo].join(' · '),
      ),
    ];
    if (next == null && deciding.isNotEmpty) {
      list.add(
        InsetGroup(
          footer:
              'L’expéditeur choisit entre une nouvelle tentative et le retour du colis. Sans réponse, le colis est à rapporter.',
          children: [
            for (final s in deciding)
              GroupRow(
                leading: IconBadge(
                  PhosphorIconsBold.hourglassMedium,
                  color: p.yellow,
                ),
                title: s['recipientName'],
                subtitle: _deadlineText(s),
              ),
          ],
        ),
      );
    }
    if (next != null) {
      final cod = (next['codAmount'] ?? 0) as num;
      final left = _waitLeft(next);
      final arrived = next['arrivedAt'] != null;
      final helpPending =
          next['helpRequestedAt'] != null && next['helpAnswer'] == null;
      final waitUntil = DateTime.tryParse(next['waitUntil'] ?? '');
      list.addAll([
        InsetGroup(
          children: [
            GroupRow(
              leading: _dot('${next['position'] + 1}', accent),
              title: '${next['address']} (${next['commune']})',
              subtitle: next['details'],
              trailing: _navButton(_pt(next), p),
            ),
            GroupRow(
              leading: Avatar(next['recipientName'] ?? '', radius: 15),
              title: next['recipientName'],
              subtitle: next['packageDescription'] ?? 'Destinataire',
              trailing: _phone(next['recipientPhone'], p, () => _call(d, next)),
            ),
            ?_clientRow(d, p),
            if (next['photoUrl'] != null)
              GroupRow(
                leading: AddressPhoto(next['photoUrl'], size: 44),
                title: 'Photo du lieu',
              ),
            if (cod > 0)
              GroupRow(
                leading: const IconBadge(
                  PhosphorIconsFill.creditCard,
                  color: accentDeep,
                ),
                title: 'Encaisser ${formatMoney(cod, d['currency'])}',
                subtitle: 'Avant de remettre le colis',
              ),
            if ((next['attempt'] ?? 1) > 1)
              GroupRow(
                leading: IconBadge(
                  PhosphorIconsBold.arrowClockwise,
                  color: accent,
                ),
                title: '2e passage · nouvelle tentative',
                subtitle:
                    'Demandée par l’expéditeur. Appelez le destinataire avant d’y aller.',
              ),
            if (helpPending)
              GroupRow(
                leading: IconBadge(
                  PhosphorIconsBold.hourglassMedium,
                  color: p.yellow,
                ),
                title: 'Expéditeur prévenu',
                subtitle: 'En attente de sa réponse · restez sur place',
              ),
            if (next['helpAnswer'] != null)
              GroupRow(
                leading: IconBadge(PhosphorIconsFill.chatText, color: accent),
                title: 'Réponse de l’expéditeur',
                subtitle: [
                  next['helpAnswer'],
                  if (waitUntil != null && waitUntil.isAfter(DateTime.now()))
                    'attendre encore ${_fmt(waitUntil.difference(DateTime.now()).inSeconds)}',
                ].join(' · '),
              ),
            if (next['cancelRequestedAt'] != null)
              GroupRow(
                leading: IconBadge(
                  PhosphorIconsBold.hourglassMedium,
                  color: p.yellow,
                ),
                title: 'Annulation en attente',
                subtitle:
                    'L’expéditeur doit confirmer · continuez vers les autres arrêts',
              ),
            // Présence sur place (détectée par le serveur)
            GroupRow(
              leading: IconBadge(
                left == null
                    ? PhosphorIconsBold.navigationArrow
                    : PhosphorIconsFill.sealCheck,
                color: left == null ? p.secondaryLabel : p.green,
              ),
              title: left == null
                  ? 'Arrivée non détectée'
                  : 'Vous êtes sur place',
              subtitle: left == null
                  ? 'Elle est enregistrée automatiquement à moins de 150 m'
                  : left > 0
                  ? 'Absence signalable dans ${_fmt(left)}'
                  : 'L’expéditeur est prévenu de votre arrivée',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: primaryButton,
                  foregroundColor: onPrimaryButton,
                ),
                onPressed: () => _deliver(d, next),
                child: Text(
                  api.deliveryCodeEnabled
                      ? 'Livrer · saisir le code'
                      : 'Marquer comme livré',
                ),
              ),
              if (arrived &&
                  !helpPending &&
                  next['cancelRequestedAt'] == null) ...[
                const SizedBox(height: 10),
                TintedButton(
                  'Injoignable · prévenir l’expéditeur',
                  icon: PhosphorIconsBold.chatText,
                  onPressed: () => _askSender(d, next),
                ),
              ],
              const SizedBox(height: 10),
              TintedButton(
                'Signaler un problème',
                icon: PhosphorIconsBold.warning,
                color: p.red,
                onPressed: () => _reportProblem(d, next),
              ),
              if (_plan.length > 1 && _plan.last != 'S:${next['id']}') ...[
                const SizedBox(height: 10),
                TintedButton(
                  'Livrer plus tard',
                  icon: PhosphorIconsBold.clock,
                  onPressed: () => _later('S:${next['id']}'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
      ]);
    }
    if (n > 1) {
      list.add(
        InsetGroup(
          header: 'Tournée',
          children: [
            for (final s in stops)
              GroupRow(
                leading: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: stopColor(context, s['status']),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${s['position'] + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                title: s['recipientName'],
                subtitle: s['status'] == 'FAILED' && s['followUp'] != null
                    ? followUpLabels[s['followUp']]
                    : (s['attempt'] ?? 1) > 1 && s['status'] == 'PENDING'
                    ? '2e passage · ${s['address']}'
                    : s['address'],
                value: s['status'] == 'FAILED'
                    ? failureLabels[s['failureReason']]
                    : stopStatusLabels[s['status']],
              ),
          ],
        ),
      );
    }
    return list;
  }

  Widget _dot(String label, Color color) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    ),
  );

  /// Ouvre la navigation Google Maps (application si installée, sinon navigateur) vers ce point
  Future<void> _openMaps(LatLng? to) async {
    if (to == null) return;
    hapticTap();
    final url = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${to.latitude},${to.longitude}',
      'travelmode': 'driving',
      'dir_action': 'navigate',
    });
    if (!await launchUrl(url, mode: LaunchMode.externalApplication) &&
        mounted) {
      showError(context, 'Impossible d’ouvrir Google Maps');
    }
  }

  /// Bouton « Itinéraire » (Google Maps) à côté d'une adresse
  Widget _navButton(LatLng? to, Palette p) => Pressable(
    onTap: () => _openMaps(to),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: ShapeDecoration(
        color: p.accentSoft,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            PhosphorIconsFill.navigationArrow,
            size: 15,
            color: accent,
          ),
          const SizedBox(width: 5),
          Text(
            'Itinéraire',
            style: TextStyles.subheadline.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  /// Numéro + bouton d'appel (l'appel passé depuis l'app est enregistré)
  Widget _phone(String? phone, Palette p, VoidCallback onCall) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        formatPhone(phone, compact: true),
        style: TextStyles.subheadline.copyWith(
          color: p.label,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(width: 8),
      Semantics(
        button: true,
        label: 'Appeler',
        child: GestureDetector(
          onTap: onCall,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: p.green, shape: BoxShape.circle),
            child: const Icon(
              PhosphorIconsFill.phone,
              size: 17,
              color: Colors.white,
            ),
          ),
        ),
      ),
    ],
  );

  /// Appelé (coche) ou à appeler, pour la liste « Avant de prendre la route »
  Widget _calledBadge(bool called, Palette p) => Icon(
    called ? PhosphorIconsFill.checkCircle : PhosphorIconsBold.circle,
    size: 20,
    color: called ? p.green : p.tertiaryLabel,
  );

  /// Reste à verser à l'entreprise, bouton de versement, historique
  List<Widget> _cashSection(Palette p) {
    final independent = _cash!['independent'] == true;
    final b = (_cash!['balance'] ?? {}) as Map;
    final history = ((_cash!['history'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
    // Livreur indépendant : seulement s'il encaisse à la livraison pour son entreprise
    if (independent &&
        (_cash!['balance'] == null ||
            (_cash!['codAllowed'] != true &&
                ((b['cod'] ?? 0) as num) == 0 &&
                history.isEmpty))) {
      return const [];
    }
    final toRemit = (b['toRemit'] ?? 0) as num;
    final pending = (b['pending'] ?? 0) as num;
    final pct = (b['sharePercent'] ?? 0) as num;
    const methods = {'CASH': 'Espèces', 'MOBILE_MONEY': 'Mobile Money', 'PAYROLL': 'Déduit de la paie'};
    const statuses = {
      'PENDING': 'À confirmer',
      'CONFIRMED': 'Confirmé',
      'REJECTED': 'Refusé',
    };
    return [
      InsetGroup(
        header: independent
            ? 'Encaissements à verser · ${_cash!['companyName'] ?? 'mon entreprise'}'
            : 'À verser à mon entreprise',
        footer: independent
            ? 'Vous gardez le prix de vos courses. Les montants encaissés à la livraison reviennent à votre entreprise, qui les reverse aux clients.'
            : pct > 0
            ? 'Vous gardez $pct % du prix de vos courses (${formatMoney(b['share'] ?? 0)} au total). Le reste, avec les paiements encaissés à la livraison, revient à votre entreprise.'
            : 'Le prix des courses et les paiements encaissés à la livraison reviennent à votre entreprise.',
        children: [
          GroupRow(
            leading: const IconBadge(PhosphorIconsFill.tray, color: accent),
            title: 'Reste à verser',
            subtitle: pending > 0
                ? '${formatMoney(pending)} en attente de confirmation'
                : null,
            value: formatMoney(toRemit),
          ),
          GroupRow(
            leading: IconBadge(PhosphorIconsFill.sealCheck, color: p.green),
            title: 'Déjà versé',
            value: formatMoney(b['confirmed'] ?? 0),
          ),
          if (independent)
            GroupRow(
              leading: IconBadge(PhosphorIconsFill.money, color: p.blue),
              title: 'Encaissé à la livraison',
              value: formatMoney(b['cod'] ?? 0),
            ),
          if (!independent)
            GroupRow(
              leading: IconBadge(PhosphorIconsFill.money, color: p.blue),
              title: 'Gagné ce mois',
              subtitle:
                  '${b['deliveries'] ?? 0} course(s) au total · ${formatMoney(b['earned'] ?? 0)}',
              value: formatMoney(b['month'] ?? 0),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
        child: FilledButton.icon(
          onPressed: toRemit - pending > 0 ? _declareRemittance : null,
          icon: const Icon(PhosphorIconsFill.arrowCircleUp),
          label: const Text('Faire un versement'),
        ),
      ),
      if (history.isNotEmpty)
        InsetGroup(
          header: 'Mes versements',
          children: [
            for (final h in history.take(8))
              GroupRow(
                leading: IconBadge(
                  h['status'] == 'CONFIRMED'
                      ? PhosphorIconsBold.check
                      : h['status'] == 'REJECTED'
                      ? PhosphorIconsBold.x
                      : PhosphorIconsBold.hourglassMedium,
                  color: h['status'] == 'CONFIRMED'
                      ? p.green
                      : h['status'] == 'REJECTED'
                      ? p.red
                      : p.yellow,
                ),
                title: formatMoney(h['amount']),
                subtitle: [
                  methods[h['method']] ?? '',
                  statuses[h['status']] ?? '',
                  if (h['reviewNote'] != null) h['reviewNote'],
                ].join(' · '),
                value: _shortDate(h['createdAt']),
              ),
          ],
        ),
    ];
  }

  String _shortDate(String iso) {
    final t = DateTime.parse(iso).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }

  // ----- Gains -----
  List<Widget> _gainsTab(Palette p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final delivered = _mine
        .where((d) => d['status'] == 'DELIVERED' && d['deliveredAt'] != null)
        .toList();
    Iterable<Map<String, dynamic>> since(DateTime t) => delivered.where(
      (d) => DateTime.parse(d['deliveredAt']).toLocal().isAfter(t),
    );
    num sum(Iterable<Map<String, dynamic>> l) =>
        l.fold<num>(0, (s, d) => s + (d['price'] ?? 0));
    final todayList = since(today);
    final weekList = since(weekStart);
    final codToday = todayList
        .expand((d) => _stopsOf(d))
        .where((s) => s['status'] == 'DELIVERED')
        .fold<num>(0, (s, x) => s + (x['codAmount'] ?? 0));

    return [
      _title('Mes gains', p),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(18),
        decoration: ShapeDecoration(
          color: ink,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Aujourd’hui',
              style: TextStyles.subheadline.copyWith(color: Colors.white70),
            ),
            Text(
              formatMoney(sum(todayList)),
              style: TextStyles.largeTitle.copyWith(color: Colors.white),
            ),
            Text(
              '${todayList.length} course(s) terminée(s)',
              style: TextStyles.subheadline.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      if (_cash != null) ..._cashSection(p),
      InsetGroup(
        children: [
          GroupRow(
            leading: IconBadge(PhosphorIconsBold.calendarBlank, color: p.blue),
            title: 'Cette semaine',
            value: formatMoney(sum(weekList)),
          ),
          GroupRow(
            leading: const IconBadge(
              PhosphorIconsFill.creditCard,
              color: accentDeep,
            ),
            title: 'Encaissé pour l’entreprise',
            subtitle: 'Aujourd’hui · paiement à la livraison',
            value: formatMoney(codToday),
          ),
        ],
      ),
      if (delivered.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 16, 7),
          child: Text(
            'DERNIÈRES COURSES',
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
        ),
        ...delivered.take(10).map((d) => DeliveryCard(d)),
      ],
    ];
  }
}

/// En-tête épinglé du panneau : poignée + contrôle segmenté
class _SheetHeader extends SliverPersistentHeaderDelegate {
  final Widget child;
  final Color color;
  _SheetHeader({required this.child, required this.color});

  @override
  double get minExtent => 82;
  @override
  double get maxExtent => 82;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    color: color,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      children: [
        const Grabber(),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: child),
      ],
    ),
  );

  @override
  bool shouldRebuild(_SheetHeader old) => true;
}

/// Interrupteur En ligne / Hors ligne (pastille)
class _StatusPill extends StatelessWidget {
  final bool online;
  final ValueChanged<bool> onChanged;
  const _StatusPill({required this.online, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () => onChanged(!online),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
        decoration: ShapeDecoration(
          color: p.card,
          shape: const StadiumBorder(),
          shadows: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: online ? p.green : p.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              online ? 'En ligne' : 'Hors ligne',
              style: TextStyles.headline.copyWith(color: p.label),
            ),
            const SizedBox(width: 4),
            CupertinoSwitch(
              value: online,
              activeTrackColor: p.green,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// Distance par la route ≈ vol d'oiseau × 1,35 (ville)
const _roadFactor = 1.35;

/// Temps estimé en ville (20 km/h en moyenne, + 2 min pour démarrer)
int _etaMin(double crowKm) =>
    ((crowKm * _roadFactor / 20) * 60).ceil().clamp(1, 999) + 2;

/// Une étape de la course : récupération ou livraison (distance et temps)
class _Leg extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _Leg({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.10),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.caption.copyWith(color: p.secondaryLabel),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.subheadline.copyWith(
                    color: p.label,
                    fontWeight: FontWeight.w700,
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

/// Carte d'une course disponible
class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final double? distance;
  final Map<String, dynamic>? myOffer;
  final Map? match;
  final VoidCallback onTap;
  const _OrderCard({
    required this.d,
    required this.distance,
    required this.myOffer,
    required this.onTap,
    this.match,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final stops = (d['stops'] as List).cast<Map<String, dynamic>>();
    final cod = stops.fold<num>(0, (s, x) => s + (x['codAmount'] ?? 0));
    return GestureDetector(
      onTap: () {
        hapticTap();
        onTap();
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(16),
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  formatMoney(d['price'], d['currency']),
                  style: TextStyles.title1.copyWith(color: p.label),
                ),
                const SizedBox(width: 8),
                if (d['speed'] == 'EXPRESS')
                  Pill(
                    'Express',
                    color: p.red,
                    icon: PhosphorIconsFill.lightning,
                  ),
                if (d['speed'] == 'SCHEDULED')
                  Pill(
                    'Dans 2 h',
                    color: p.blue,
                    icon: PhosphorIconsBold.clock,
                  ),
                if (match?['kind'] == 'ROUTE')
                  Pill(
                    'Sur votre trajet',
                    color: p.blue,
                    icon: PhosphorIconsBold.arrowsSplit,
                  ),
                const Spacer(),
                Icon(vehicleIcons[d['vehicleType']], color: p.label, size: 26),
              ],
            ),
            const SizedBox(height: 8),
            // Jusqu'à la récupération des colis, puis la livraison
            Row(
              children: [
                Expanded(
                  child: _Leg(
                    icon: PhosphorIconsFill.package,
                    label: 'Récupération',
                    value: distance != null && distance!.isFinite
                        ? '${km(distance! * _roadFactor)} · ~${_etaMin(distance!)} min'
                        : 'Position inconnue',
                    color: accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Leg(
                    icon: PhosphorIconsFill.flag,
                    label: stops.length > 1
                        ? 'Livraison · ${stops.length} arrêts'
                        : 'Livraison',
                    value: [
                      if (d['distanceKm'] != null) km(d['distanceKm']),
                      if (d['durationMin'] != null) '~${d['durationMin']} min',
                    ].join(' · '),
                    color: p.label,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PointLine(title: '${d['pickupAddress']} (${d['pickupCommune']})'),
            PointLine(
              marker: stops.length > 1 ? '${stops.length}' : '1',
              title: stops.length > 1
                  ? '${stops.first['commune']} et ${stops.length - 1} autre(s) arrêt(s)'
                  : '${stops.first['address']} (${stops.first['commune']})',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Avatar(d['client']?['name'] ?? '?', radius: 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${d['client']?['name'] ?? ''} · ${timeAgo(d['createdAt'])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                ),
                if (cod > 0) CodBadge(cod, currency: d['currency']),
              ],
            ),
            if (d['assignedDriverId'] != null &&
                d['assignedDriverId'] == Api.instance.user?['id']) ...[
              const SizedBox(height: 10),
              const Pill(
                'Affectée par votre entreprise',
                color: accent,
                icon: PhosphorIconsFill.buildings,
              ),
            ],
            if (myOffer != null) ...[
              const SizedBox(height: 10),
              Pill(
                'Votre proposition : ${formatMoney(myOffer!['price'], d['currency'])} · en attente',
                color: accentDeep,
                icon: PhosphorIconsBold.hourglassMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Étiquette de prix sur la carte
class _PriceTag extends StatelessWidget {
  final num price;
  final int stops;
  final String? currency;
  const _PriceTag(this.price, {this.stops = 1, this.currency});

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: const ShapeDecoration(
      color: Color(0xFF1C1C1E),
      shape: StadiumBorder(side: BorderSide(color: Colors.white, width: 2)),
      shadows: [BoxShadow(color: Color(0x40000000), blurRadius: 8)],
    ),
    child: Text(
      stops > 1
          ? '${formatMoney(price, currency)} · $stops'
          : formatMoney(price, currency),
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );
}

/// Bandeau : l'entreprise ne peut pas faire travailler ses livreurs (abonnement, crédit)
class _BlockedBanner extends StatelessWidget {
  final String reason;
  const _BlockedBanner(this.reason);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        shadows: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsFill.warning, color: p.red, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Courses indisponibles',
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                Text(
                  reason,
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Formulaire de versement : montant, mode, référence et capture (Mobile Money)
class _RemittanceSheet extends StatefulWidget {
  final int max;
  const _RemittanceSheet({required this.max});
  @override
  State<_RemittanceSheet> createState() => _RemittanceSheetState();
}

class _RemittanceSheetState extends State<_RemittanceSheet> {
  late final _amount = TextEditingController(text: '${widget.max}');
  final _reference = TextEditingController();
  final _note = TextEditingController();
  String _method = 'CASH';
  String? _proof;
  bool _uploading = false;

  Future<void> _pickProof() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final url = await Api.instance.upload(File(file.path));
      if (mounted) setState(() => _proof = url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _submit() {
    final n = int.tryParse(_amount.text.replaceAll(' ', ''));
    if (n == null || n < 100)
      return showError(context, 'Montant : ${formatMoney(100)} minimum');
    if (n > widget.max) {
      return showError(
        context,
        'Il vous reste ${formatMoney(widget.max)} à verser',
      );
    }
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(context, {
      'amount': n,
      'method': _method,
      'reference': _method == 'MOBILE_MONEY' ? opt(_reference) : null,
      'proofUrl': _method == 'MOBILE_MONEY' ? _proof : null,
      'note': opt(_note),
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            const Center(child: Grabber()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'FAIRE UN VERSEMENT',
                style: TextStyles.displaySmall.copyWith(color: p.label),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                'Reste à verser : ${formatMoney(widget.max)}. Votre entreprise confirme à réception.',
                style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: _method,
                onValueChanged: (v) => setState(() => _method = v ?? 'CASH'),
                children: const {
                  'CASH': Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Espèces au bureau'),
                  ),
                  'MOBILE_MONEY': Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Mobile Money'),
                  ),
                },
              ),
            ),
            InsetGroup(
              children: [
                GroupField(
                  controller: _amount,
                  placeholder: 'Montant (${currencyLabel()})',
                  icon: PhosphorIconsBold.money,
                  keyboardType: TextInputType.number,
                ),
                if (_method == 'MOBILE_MONEY') ...[
                  GroupField(
                    controller: _reference,
                    placeholder: 'Référence de la transaction',
                    icon: PhosphorIconsBold.hash,
                  ),
                  GroupRow(
                    leading: _proof != null
                        ? AddressPhoto(_proof!, size: 40)
                        : Icon(
                            PhosphorIconsBold.image,
                            color: p.secondaryLabel,
                            size: 20,
                          ),
                    title: _proof != null
                        ? 'Capture ajoutée'
                        : 'Ajouter la capture du transfert',
                    titleColor: _proof != null ? null : accent,
                    trailing: _uploading
                        ? const CupertinoActivityIndicator()
                        : null,
                    onTap: _uploading ? null : _pickProof,
                  ),
                ],
                GroupField(
                  controller: _note,
                  placeholder: 'Note (facultatif)',
                  icon: PhosphorIconsBold.chatTeardropText,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: FilledButton(
                onPressed: _uploading ? null : _submit,
                child: const Text('Déclarer le versement'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Étape de la tournée sur la carte : numéro dans l'ordre de passage, couleur selon l'action
/// (vert = récupérer, violet = livrer, jaune = rapporter). La prochaine étape est plus grande.
class _TourPin extends StatelessWidget {
  final int number;
  final Color color;
  final IconData icon;
  final bool next;
  final bool faded;
  const _TourPin({
    required this.number,
    required this.color,
    required this.icon,
    required this.next,
    required this.faded,
  });

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: faded && !next ? 0.6 : 1,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: next ? 3.5 : 2.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              '$number',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: next ? 16 : 13,
              ),
            ),
          ),
        ),
        // Pastille de l'action (récupérer, livrer, rapporter)
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.5),
            ),
            child: Icon(icon, size: 11, color: color),
          ),
        ),
      ],
    ),
  );
}
