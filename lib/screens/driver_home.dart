import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
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
import '../main.dart';
import '../realtime.dart';
import 'driver_course_sheet.dart';
import 'widgets.dart';

/// Dev / tests : photo déjà envoyée utilisée à la place de l'appareil photo (--dart-define=DEV_PHOTO=/uploads/x.jpg)
const _devPhoto = String.fromEnvironment('DEV_PHOTO');

/// Accueil livreur : carte plein écran + panneau (Courses · En cours · Gains)
class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final api = Api.instance;
  final _map = MapController();

  int _tab = 0;
  ScrollController? _sheetScroll;
  bool _online = false;
  LatLng? _me;
  Timer? _timer;
  Timer? _heartbeat;
  Timer? _clock;
  StreamSubscription<Position>? _gps;
  int _absenceWaitMin = 5;

  List<Map<String, dynamic>> _available = [];

  /// Gains et versements (onglet « Gains »)
  Map<String, dynamic>? _cash;

  /// Raison du blocage par l'entreprise (abonnement expiré, crédit épuisé), sinon null
  String? _blocked;
  List<Map<String, dynamic>> _mine = [];
  Map<String, Map<String, dynamic>> _myOffers = {};

  RouteInfo? _activeRoute;
  String? _activeRouteKey;

  List<Map<String, dynamic>> get _active => _mine
      .where((d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']))
      .toList();
  Map<String, dynamic>? get _current => _active.isEmpty ? null : _active.first;

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
    _load();
    api
        .grid()
        .then(
          (g) => _absenceWaitMin = (g['absenceWaitMin'] as num?)?.ceil() ?? 5,
        )
        .catchError((_) => 5);
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
    s.on('delivery:cancelled', _onDeliveryCancelled);
    s.on('remittance:updated', _onRemittance);
    SharedPreferences.getInstance().then((p) {
      if (p.getBool('driver_online') == true) _goOnline();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _stopGps();
    final s = Realtime.instance.socket;
    s.off('deliveries:changed', _onChanged);
    s.off('offer:accepted', _onOfferAccepted);
    s.off('offer:rejected', _onOfferRejected);
    s.off('stop:arrived', _onArrived);
    s.off('stop:cancelled', _onStopCancelled);
    s.off('stop:cancel-refused', _onCancelRefused);
    s.off('delivery:cancelled', _onDeliveryCancelled);
    s.off('remittance:updated', _onRemittance);
    super.dispose();
  }

  void _onChanged(dynamic _) => _load();

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

  void _onDeliveryCancelled(dynamic e) {
    _load();
    if (mounted && e is Map) {
      final fee = (e['fee'] ?? 0) as num;
      showError(
        context,
        fee > 0
            ? 'Course annulée par l’expéditeur · frais de déplacement ${fcfa(fee)} (récupérés par votre entreprise)'
            : 'Course annulée par l’expéditeur',
      );
    }
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
    final note = await prompt(
      context,
      'Le destinataire annule',
      message:
          'L’expéditeur doit confirmer l’annulation. Sans réponse, elle est acceptée automatiquement. En attendant, continuez vers les autres arrêts.',
      placeholder: 'Ex. : il a appelé, il ne veut plus du colis',
      ok: 'Envoyer',
    );
    if (note == null) return;
    await _run(
      () => api.requestStopCancel(
        d['id'],
        stop['id'],
        note: note.isEmpty ? null : note,
      ),
      'Demande envoyée à l’expéditeur',
    );
  }

  /// Retour des colis non livrés : l'expéditeur donne son code
  Future<void> _confirmReturn(Map d) async {
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

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        api.available(),
        api.driverDeliveries(),
        api.myOffers(),
        api.billingStatus().catchError((_) => <String, dynamic>{'ok': true}),
        api.myCash().catchError((_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        final billing = r[3] as Map<String, dynamic>;
        final cash = r[4] as Map<String, dynamic>;
        if (cash.isNotEmpty) _cash = cash;
        _blocked = billing['ok'] == false ? billing['reason'] as String? : null;
        _available = r[0].cast<Map<String, dynamic>>();
        _mine = r[1].cast<Map<String, dynamic>>();
        _myOffers = {
          for (final o in r[2].cast<Map<String, dynamic>>())
            o['deliveryId'] as String: o,
        };
        if (_me != null) {
          _available.sort((a, b) => _distanceTo(a).compareTo(_distanceTo(b)));
        }
      });
      _refreshActiveRoute();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  double _distanceTo(Map d) {
    final p = pointOf(d, 'pickup');
    return (_me == null || p == null) ? double.infinity : distanceKm(_me!, p);
  }

  Future<void> _refreshActiveRoute() async {
    final d = _current;
    if (d == null) {
      if (_activeRoute != null) setState(() => _activeRoute = null);
      _activeRouteKey = null;
      return;
    }
    final to = _targetOf(d);
    final from = _me ?? pointOf(d, 'pickup');
    if (to == null || from == null) return;
    final key = '${d['id']}-${d['status']}-${_nextStop(d)?['id']}';
    if (key == _activeRouteKey) return;
    _activeRouteKey = key;
    try {
      final r = await api.route(from, to);
      if (!mounted) return;
      setState(() => _activeRoute = r);
      fitPoints(
        _map,
        [from, to, ...r.points],
        padding: EdgeInsets.fromLTRB(
          50,
          110,
          50,
          MediaQuery.of(context).size.height * 0.5,
        ),
      );
    } catch (_) {}
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
    if (devPosition == null) {
      _gps =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen(
            (p) => _sendPosition(LatLng(p.latitude, p.longitude)),
            onError: (_) {},
          );
    }
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
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
    Realtime.instance.socket.emit('driver:offline');
    setState(() => _online = false);
    (await SharedPreferences.getInstance()).setBool('driver_online', false);
  }

  void _stopGps() {
    _gps?.cancel();
    _gps = null;
    _heartbeat?.cancel();
  }

  void _sendPosition(LatLng p) {
    if (mounted) setState(() => _me = p);
    Realtime.instance.socket.emit('driver:location', {
      'lat': p.latitude,
      'lng': p.longitude,
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
              'Avez-vous encaissé ${fcfa(cod)} auprès de ${stop['recipientName']} ?',
          ok: 'Oui, encaissé',
        )) {
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
    final reason = await showActions<String>(
      context,
      title: 'Problème avec ${stop['recipientName']}',
      message: 'Appelez d’abord le destinataire : ${stop['recipientPhone']}',
      actions: [
        ('Destinataire absent ou injoignable', 'ABSENT', false),
        ('Le destinataire refuse le colis', 'REFUSED', true),
        if (stop['cancelRequestedAt'] == null)
          ('Le destinataire annule (il a appelé)', 'CANCEL', false),
      ],
    );
    if (reason == null || !mounted) return;
    if (reason == 'CANCEL') return _requestCancel(d, stop);
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
      'Échec signalé — l’expéditeur est prévenu',
    );
  }

  String _fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final active = _current;
    final target = active == null ? null : _targetOf(active);

    return Scaffold(
      backgroundColor: p.background,
      body: Stack(
        children: [
          LetoMap(
            controller: _map,
            layers: [
              if (_activeRoute != null)
                routeLayer(
                  _activeRoute!.points,
                  color: active?['status'] == 'ACCEPTED' ? p.blue : p.green,
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
                            stops: _stopsOf(d).length,
                          ),
                        ),
                      ),
                  if (active != null)
                    for (final s in _stopsOf(active))
                      stopMarker(
                        context,
                        _pt(s),
                        s['position'] + 1,
                        status: s['status'],
                      ),
                  if (active != null &&
                      active['status'] == 'ACCEPTED' &&
                      target != null)
                    pickupMarker(target),
                  if (_me != null) myMarker(_me!),
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
                        CupertinoIcons.person_crop_circle,
                        onTap: () => showAccountSheet(
                          context,
                          items: [
                            (
                              CupertinoIcons.clock_fill,
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
                        CupertinoIcons.location_fill,
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
                            child: _BlockedBanner(_blocked!),
                          ),
                  ),
                ],
              ),
            ),
          ),
          DraggableScrollableSheet(
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
            icon: const Icon(CupertinoIcons.power),
            label: const Text('Passer en ligne'),
          ),
        ),
      ];
    }
    return [
      _title(
        'Courses disponibles',
        p,
        subtitle: _available.isEmpty
            ? 'Aucune course pour le moment. Elles arrivent en temps réel.'
            : 'En temps réel · les plus proches d’abord',
      ),
      for (final d in _available)
        _OrderCard(
          d: d,
          distance: _me == null ? null : _distanceTo(d),
          myOffer: _myOffers[d['id']],
          onTap: () => _openCourse(d),
        ),
    ];
  }

  // ----- En cours -----
  List<Widget> _activeTab(Palette p) {
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
            icon: CupertinoIcons.list_bullet,
            onPressed: () => _setTab(0),
          ),
        ),
      ];
    }
    final stops = _stopsOf(d);
    final n = stops.length;
    final done = stops.where((s) => s['status'] != 'PENDING').length;
    final routeInfo = _activeRoute == null
        ? null
        : '${_activeRoute!.durationMin} min · ${km(_activeRoute!.distanceKm)}';

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
              leading: _dot('A', p.green),
              title: '${d['pickupAddress']} (${d['pickupCommune']})',
              subtitle: d['pickupDetails'],
              trailing: _navButton(pointOf(d, 'pickup'), p),
            ),
            GroupRow(
              leading: Avatar(sender, radius: 15),
              title: sender,
              subtitle: 'Expéditeur',
              trailing: _phone(d['pickupPhone'], p),
            ),
            if (d['pickupPhotoUrl'] != null)
              GroupRow(
                leading: AddressPhoto(d['pickupPhotoUrl'], size: 44),
                title: 'Photo du lieu',
              ),
            if ((d['courierComment'] ?? '').toString().isNotEmpty)
              GroupRow(
                leading: Icon(
                  CupertinoIcons.chat_bubble_text,
                  color: p.secondaryLabel,
                  size: 20,
                ),
                title: d['courierComment'],
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton(
            onPressed: () => _run(
              () => api.pickup(d['id']),
              n > 1
                  ? 'Colis récupérés — début de la tournée'
                  : 'Colis récupéré',
            ),
            child: Text(
              n > 1 ? 'J’ai récupéré les $n colis' : 'J’ai récupéré le colis',
            ),
          ),
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
          footer:
              'Remettez les colis à l’expéditeur : il vous donne son code de retour pour terminer la tournée.',
          children: [
            GroupRow(
              leading: _dot('A', p.green),
              title: '${d['pickupAddress']} (${d['pickupCommune']})',
              trailing: _navButton(pointOf(d, 'pickup'), p),
            ),
            GroupRow(
              leading: Avatar(sender, radius: 15),
              title: sender,
              subtitle: 'Expéditeur',
              trailing: _phone(d['pickupPhone'], p),
            ),
            for (final s in back)
              GroupRow(
                leading: Icon(
                  CupertinoIcons.cube_box,
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
            child: const Text('Saisir le code de retour'),
          ),
        ),
      ];
    }

    // Étape 2 : tournée, arrêt par arrêt
    final next = _nextStop(d);
    final list = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: StatusSteps(d['status']),
      ),
      _title(
        next == null
            ? 'Tournée terminée'
            : (n > 1
                  ? 'Arrêt ${next['position'] + 1} sur $n'
                  : 'Vers le destinataire'),
        p,
        subtitle: [if (n > 1) '$done/$n traités', ?routeInfo].join(' · '),
      ),
    ];
    if (next != null) {
      final cod = (next['codAmount'] ?? 0) as num;
      final left = _waitLeft(next);
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
              trailing: _phone(next['recipientPhone'], p),
            ),
            if (next['photoUrl'] != null)
              GroupRow(
                leading: AddressPhoto(next['photoUrl'], size: 44),
                title: 'Photo du lieu',
              ),
            if (cod > 0)
              GroupRow(
                leading: const IconBadge(
                  CupertinoIcons.creditcard_fill,
                  color: accentDeep,
                ),
                title: 'Encaisser ${fcfa(cod)}',
                subtitle: 'Avant de remettre le colis',
              ),
            if (next['cancelRequestedAt'] != null)
              GroupRow(
                leading: IconBadge(CupertinoIcons.hourglass, color: p.yellow),
                title: 'Annulation en attente',
                subtitle:
                    'L’expéditeur doit confirmer · continuez vers les autres arrêts',
              ),
            // Présence sur place (détectée par le serveur)
            GroupRow(
              leading: IconBadge(
                left == null
                    ? CupertinoIcons.location
                    : CupertinoIcons.checkmark_seal_fill,
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
                style: FilledButton.styleFrom(backgroundColor: p.green),
                onPressed: () => _deliver(d, next),
                child: const Text('Livrer · saisir le code'),
              ),
              const SizedBox(height: 10),
              TintedButton(
                'Signaler un problème',
                icon: CupertinoIcons.exclamationmark_triangle,
                color: p.red,
                onPressed: () => _reportProblem(d, next),
              ),
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
                subtitle: s['address'],
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
            CupertinoIcons.location_north_fill,
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

  Widget _phone(String? phone, Palette p) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(CupertinoIcons.phone_fill, size: 15, color: p.green),
      const SizedBox(width: 4),
      SelectableText(
        phone ?? '',
        style: TextStyles.subheadline.copyWith(
          color: p.label,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  /// Reste à verser à l'entreprise, bouton de versement, historique
  List<Widget> _cashSection(Palette p) {
    final b = (_cash!['balance'] ?? {}) as Map;
    final history = ((_cash!['history'] as List?) ?? [])
        .cast<Map<String, dynamic>>();
    final toRemit = (b['toRemit'] ?? 0) as num;
    final pending = (b['pending'] ?? 0) as num;
    final pct = (b['sharePercent'] ?? 0) as num;
    const methods = {'CASH': 'Espèces', 'MOBILE_MONEY': 'Mobile Money'};
    const statuses = {
      'PENDING': 'À confirmer',
      'CONFIRMED': 'Confirmé',
      'REJECTED': 'Refusé',
    };
    return [
      InsetGroup(
        header: 'À verser à mon entreprise',
        footer: pct > 0
            ? 'Vous gardez $pct % du prix de vos courses (${fcfa(b['share'] ?? 0)} au total). Le reste, avec les paiements encaissés à la livraison, revient à votre entreprise.'
            : 'Le prix des courses et les paiements encaissés à la livraison reviennent à votre entreprise.',
        children: [
          GroupRow(
            leading: const IconBadge(
              CupertinoIcons.tray_arrow_up_fill,
              color: accent,
            ),
            title: 'Reste à verser',
            subtitle: pending > 0
                ? '${fcfa(pending)} en attente de confirmation'
                : null,
            value: fcfa(toRemit),
          ),
          GroupRow(
            leading: IconBadge(
              CupertinoIcons.checkmark_seal_fill,
              color: p.green,
            ),
            title: 'Déjà versé',
            value: fcfa(b['confirmed'] ?? 0),
          ),
          GroupRow(
            leading: IconBadge(
              CupertinoIcons.money_dollar_circle_fill,
              color: p.blue,
            ),
            title: 'Gagné ce mois',
            subtitle:
                '${b['deliveries'] ?? 0} course(s) au total · ${fcfa(b['earned'] ?? 0)}',
            value: fcfa(b['month'] ?? 0),
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
        child: FilledButton.icon(
          onPressed: toRemit - pending > 0 ? _declareRemittance : null,
          icon: const Icon(CupertinoIcons.arrow_up_circle_fill),
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
                      ? CupertinoIcons.checkmark_alt
                      : h['status'] == 'REJECTED'
                      ? CupertinoIcons.xmark
                      : CupertinoIcons.hourglass,
                  color: h['status'] == 'CONFIRMED'
                      ? p.green
                      : h['status'] == 'REJECTED'
                      ? p.red
                      : p.yellow,
                ),
                title: fcfa(h['amount']),
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
          gradient: const LinearGradient(
            colors: [accentLight, accent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
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
              fcfa(sum(todayList)),
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
            leading: IconBadge(CupertinoIcons.calendar, color: p.blue),
            title: 'Cette semaine',
            value: fcfa(sum(weekList)),
          ),
          GroupRow(
            leading: const IconBadge(
              CupertinoIcons.creditcard_fill,
              color: accentDeep,
            ),
            title: 'Encaissé pour l’entreprise',
            subtitle: 'Aujourd’hui · paiement à la livraison',
            value: fcfa(codToday),
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

/// Carte d'une course disponible
class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final double? distance;
  final Map<String, dynamic>? myOffer;
  final VoidCallback onTap;
  const _OrderCard({
    required this.d,
    required this.distance,
    required this.myOffer,
    required this.onTap,
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
                  fcfa(d['price']),
                  style: TextStyles.title1.copyWith(color: p.label),
                ),
                const SizedBox(width: 8),
                if (d['speed'] == 'EXPRESS')
                  Pill('Express', color: p.red, icon: CupertinoIcons.bolt_fill),
                if (d['speed'] == 'SCHEDULED')
                  Pill('Dans 2 h', color: p.blue, icon: CupertinoIcons.clock),
                const Spacer(),
                Icon(vehicleIcons[d['vehicleType']], color: p.label, size: 26),
              ],
            ),
            Text(
              [
                if (distance != null && distance!.isFinite)
                  'à ${km(distance!)}',
                if (stops.length > 1) '${stops.length} arrêts',
                if (d['distanceKm'] != null) 'trajet ${km(d['distanceKm'])}',
              ].join(' · '),
              style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
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
                if (cod > 0) CodBadge(cod),
              ],
            ),
            if (myOffer != null) ...[
              const SizedBox(height: 10),
              Pill(
                'Votre proposition : ${fcfa(myOffer!['price'])} · en attente',
                color: accentDeep,
                icon: CupertinoIcons.hourglass,
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
  const _PriceTag(this.price, {this.stops = 1});

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: const ShapeDecoration(
      color: Color(0xFF1C1C1E),
      shape: StadiumBorder(side: BorderSide(color: Colors.white, width: 2)),
      shadows: [BoxShadow(color: Color(0x40000000), blurRadius: 8)],
    ),
    child: Text(
      stops > 1 ? '${fcfa(price)} · $stops' : fcfa(price),
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
          Icon(
            CupertinoIcons.exclamationmark_triangle_fill,
            color: p.red,
            size: 22,
          ),
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
      return showError(context, 'Montant : 100 F minimum');
    if (n > widget.max) {
      return showError(context, 'Il vous reste ${fcfa(widget.max)} à verser');
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
                'Reste à verser : ${fcfa(widget.max)}. Votre entreprise confirme à réception.',
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
                  placeholder: 'Montant (FCFA)',
                  icon: CupertinoIcons.money_dollar,
                  keyboardType: TextInputType.number,
                ),
                if (_method == 'MOBILE_MONEY') ...[
                  GroupField(
                    controller: _reference,
                    placeholder: 'Référence de la transaction',
                    icon: CupertinoIcons.number,
                  ),
                  GroupRow(
                    leading: _proof != null
                        ? AddressPhoto(_proof!, size: 40)
                        : Icon(
                            CupertinoIcons.photo,
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
                  icon: CupertinoIcons.text_bubble,
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
