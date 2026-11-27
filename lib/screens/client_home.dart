import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../live_activity.dart';
import '../main.dart';
import '../models.dart';
import 'address_book_screen.dart';
import 'company_picker.dart';
import 'order_screen.dart';
import 'place_search.dart';
import 'share_codes.dart';
import 'tracking_screen.dart';
import 'widgets.dart';

enum _Mode { pickup, dropoffOnMap, summary }

const _maxStops = 10;

/// Accueil client / boutique : départ (épingle), une ou plusieurs adresses de livraison,
/// ordre de passage optimisé, choix de l'offre.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> {
  final api = Api.instance;
  final _map = MapController();

  _Mode _mode = _Mode.pickup;
  LatLng _center = abidjan;
  bool _moving = false;
  Place? _centerPlace;
  bool _lookingUp = true;
  int? _eta;
  int _lookupSeq = 0;

  Place? _pickup;
  final List<StopDraft> _stops = [];
  Map<String, dynamic>? _quote;
  bool _quoting = false;
  String _vehicle = 'MOTO';

  /// Entreprise choisie (null = toutes) — l'entreprise favorite est présélectionnée
  ChosenCompany? _company;

  Map<String, dynamic>? _active;

  /// Livreurs en ligne autour du centre de la carte (rafraîchis toutes les 15 s)
  List<NearbyDriver> _drivers = [];
  Timer? _driversTimer;

  /// Le client a déplacé la carte lui-même : plus de recadrage automatique
  bool _userMoved = false;

  /// Point de départ pour lequel la carte a déjà été recadrée sur les livreurs
  LatLng? _fittedFor;

  @override
  void initState() {
    super.initState();
    repeatOrder.addListener(_onRepeat);
    _loadActive();
    // Livreurs autour : chargés une fois l'entreprise favorite connue (lecture locale, instantanée)
    loadFavoriteCompany().then((c) {
      if (!mounted) return;
      setState(() => _company = c);
      _loadDrivers();
    });
    _lookupCenter();
    _locateMe();
    // Rafraîchis seulement quand l'accueil est visible (pas sous le suivi, pas en arrière-plan)
    _driversTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          !TickerMode.getNotifier(context).value) {
        return;
      }
      _loadDrivers();
    });
  }

  @override
  void dispose() {
    repeatOrder.removeListener(_onRepeat);
    _driversTimer?.cancel();
    super.dispose();
  }

  /// « Répéter » depuis le suivi d'une course : même départ, mêmes destinataires, même engin
  void _onRepeat() {
    final d = repeatOrder.value;
    if (d == null || !mounted) return;
    repeatOrder.value = null;
    final stops = ((d['stops'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .where((s) => s['status'] != 'CANCELLED')
        .take(_maxStops);
    setState(() {
      _pickup = Place(
        d['pickupAddress'] ?? '',
        d['pickupCommune'] ?? '',
        LatLng(
          (d['pickupLat'] as num).toDouble(),
          (d['pickupLng'] as num).toDouble(),
        ),
      );
      _vehicle = d['vehicleType'] ?? _vehicle;
      _stops
        ..clear()
        ..addAll([
          for (final s in stops)
            StopDraft(
              Place(
                s['address'] ?? '',
                s['recipientName'] ?? '',
                LatLng(
                  (s['lat'] as num).toDouble(),
                  (s['lng'] as num).toDouble(),
                ),
              ),
              name: s['recipientName'] ?? '',
              phone: s['recipientPhone'] ?? '',
              details: s['details'] ?? '',
            )..description = s['packageDescription'] ?? '',
        ]);
    });
    if (_stops.isEmpty) return;
    showInfo(context, 'Commande reprise : vérifiez puis continuez');
    _showSummary();
  }

  Future<void> _loadDrivers() async {
    try {
      final l = await api.nearbyDrivers(_center, companyId: _company?.id);
      if (!mounted) return;
      setState(() => _drivers = l);
      _fitDriversIfHidden();
    } catch (_) {
      // carte sans livreurs : sans gravité
    }
  }

  // ---------- Carte ----------

  /// Livreurs en ligne mais hors de l'écran : on dézoome (sans déplacer le point de départ)
  /// pour montrer les 3 plus proches. Une fois par point de départ, jamais après un geste du client.
  void _fitDriversIfHidden() {
    if (_mode != _Mode.pickup || _userMoved || _drivers.isEmpty) return;
    final center = _center;
    const dist = Distance();
    if (_fittedFor != null && dist(_fittedFor!, center) < 50) return;
    final MapCamera cam;
    try {
      cam = _map.camera;
    } catch (_) {
      return; // carte pas encore affichée
    }
    _fittedFor = center;
    if (_drivers.any((d) => cam.visibleBounds.contains(d.point))) return;
    final near = [..._drivers]
      ..sort((a, b) => dist(center, a.point).compareTo(dist(center, b.point)));
    // Points symétriques autour du départ : le centre de la carte (et donc l'adresse) ne bouge pas
    final pts = <LatLng>[
      center,
      for (final d in near.take(3)) ...[
        d.point,
        LatLng(
          2 * center.latitude - d.point.latitude,
          2 * center.longitude - d.point.longitude,
        ),
      ],
    ];
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.all(96),
        maxZoom: cam.zoom,
        minZoom: 12,
      ),
    );
  }

  Future<void> _locateMe() async {
    final pos = await myPosition();
    if (pos == null || !mounted) return;
    _map.move(pos, 16);
    _center = pos;
    _userMoved = false;
    _lookupCenter();
    _loadDrivers();
  }

  void _onMove(MapCamera camera, bool gesture) {
    _center = camera.center;
    if (gesture) _userMoved = true;
    if (gesture && !_moving) setState(() => _moving = true);
  }

  void _onMoveEnd() {
    if (_mode == _Mode.summary) return;
    setState(() => _moving = false);
    _lookupCenter();
    _loadDrivers();
  }

  Future<void> _lookupCenter() async {
    final seq = ++_lookupSeq;
    final p = _center;
    setState(() => _lookingUp = true);
    try {
      final placeF = api.reverse(p);
      final etaF = _mode == _Mode.pickup ? api.eta(p) : Future.value(_eta);
      final place = await placeF;
      final eta = await etaF;
      if (!mounted || seq != _lookupSeq) return;
      setState(() {
        _centerPlace = place;
        _eta = eta;
      });
    } catch (_) {
    } finally {
      if (mounted && seq == _lookupSeq) setState(() => _lookingUp = false);
    }
  }

  void _moveTo(Place p) {
    _map.move(p.point, 17);
    _center = p.point;
    _userMoved = false;
    setState(() => _centerPlace = p);
    if (_mode == _Mode.pickup) {
      api.eta(p.point).then((e) => mounted ? setState(() => _eta = e) : null);
    }
  }

  Place get _centerAsPlace => Place(
    _centerPlace?.label ?? 'Point sur la carte',
    _centerPlace?.sublabel ?? '',
    _center,
  );

  // ---------- Départ / arrêts ----------

  Future<void> _searchPickup() async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(title: 'Départ', near: _center),
      ),
    );
    if (res is Place) {
      if (_mode == _Mode.summary) {
        setState(() => _pickup = res);
        _refreshQuote();
      } else {
        _moveTo(res);
      }
    }
  }

  /// Ajoute (ou remplace, si [replace] est fourni) une adresse de livraison
  Future<void> _addStop({int? replace}) async {
    if (_mode == _Mode.pickup) _pickup = _centerAsPlace;
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: 'Adresse de livraison',
          near: _pickup!.point,
          dropoff: true,
        ),
      ),
    );
    if (!mounted) return;
    StopDraft? draft;
    if (res is StopDraft) draft = res;
    if (res is Place) draft = StopDraft(res);
    if (draft != null) {
      setState(
        () => replace == null ? _stops.add(draft!) : _stops[replace] = draft!,
      );
      _showSummary();
    } else if (res == chooseOnMap) {
      if (replace != null) setState(() => _stops.removeAt(replace));
      setState(() => _mode = _Mode.dropoffOnMap);
      if (_stops.isNotEmpty) _map.move(_stops.last.place.point, 16);
      _lookupCenter();
    }
  }

  void _confirmDropoffOnMap() {
    hapticTap();
    setState(() => _stops.add(StopDraft(_centerAsPlace)));
    _showSummary();
  }

  void _showSummary() {
    setState(() => _mode = _Mode.summary);
    _refreshQuote();
  }

  /// Devis : réordonne les arrêts selon l'ordre de passage optimisé
  Future<void> _refreshQuote() async {
    setState(() {
      _quote = null;
      _quoting = true;
    });
    try {
      final q = await api.quote(_pickup!.point, [
        for (final s in _stops) (point: s.place.point, cod: false),
      ], companyId: _company?.id);
      if (!mounted) return;
      final order = (q['order'] as List).cast<int>();
      final reordered = [for (final i in order) _stops[i]];
      setState(() {
        _stops
          ..clear()
          ..addAll(reordered);
        _quote = q;
      });
      fitPoints(
        _map,
        [
          _pickup!.point,
          ..._stops.map((s) => s.place.point),
          ...latLngList(q['points']),
        ],
        padding: EdgeInsets.fromLTRB(
          50,
          120,
          50,
          MediaQuery.of(context).size.height * 0.05,
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _backToPickup() async {
    if (_stops.length > 1 &&
        !await confirm(
          context,
          'Effacer les ${_stops.length} adresses ?',
          ok: 'Effacer',
          destructive: true,
        )) {
      return;
    }
    setState(() {
      _mode = _Mode.pickup;
      _stops.clear();
      _quote = null;
    });
    if (_pickup != null) _moveTo(_pickup!);
  }

  Future<void> _continue() async {
    final created = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => OrderScreen(
          pickup: _pickup!,
          stops: _stops,
          quote: _quote!,
          vehicle: _vehicle,
          company: _company,
          onPickupChanged: (pl) => _pickup = pl,
          onVehicleChanged: (v) => _vehicle = v,
        ),
      ),
    );
    if (!mounted) return;
    if (created == null) {
      // Retour sans commander : les adresses ont pu changer dans l'écran de détails
      if (_stops.isEmpty) {
        _backToPickup();
      } else {
        _refreshQuote();
      }
      return;
    }
    setState(() {
      _mode = _Mode.pickup;
      _stops.clear();
      _quote = null;
    });
    // Partage des codes aux destinataires (WhatsApp…), puis suivi
    if (api.deliveryCodeEnabled) await showShareCodes(context, created);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TrackingScreen(created['id'])),
    );
    _loadActive();
  }

  Future<void> _loadActive() async {
    try {
      final list = await api.myDeliveries();
      final active = list.cast<Map<String, dynamic>>().where(
        (d) => ['PENDING', 'ACCEPTED', 'PICKED_UP'].contains(d['status']),
      );
      if (mounted) {
        setState(() => _active = active.isEmpty ? null : active.first);
      }
      DeliveryLive.instance.sync(
        active.isEmpty ? null : active.first,
        driver: false,
      );
    } catch (_) {}
  }

  void _openAccount() => showAccountSheet(
    context,
    items: [
      (
        PhosphorIconsFill.package,
        accent,
        'Mes livraisons',
        () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HistoryScreen(
              load: api.myDeliveries,
              onTap: (ctx, d) => Navigator.push(
                ctx,
                MaterialPageRoute(builder: (_) => TrackingScreen(d['id'])),
              ),
            ),
          ),
        ).then((_) => _loadActive()),
      ),
      (
        PhosphorIconsFill.book,
        Palette.of(context).blue,
        'Carnet d’adresses',
        () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddressBookScreen()),
        ),
      ),
    ],
  );

  // ---------- Arrêts ----------

  /// Feuille « Arrêts » : voir, ajouter et retirer les adresses de livraison
  Future<void> _openStopsSheet() async {
    final p = Palette.of(context);
    var changed = false;
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: p.card,
      shape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Grabber(),
                const SizedBox(height: 16),
                Text(
                  'ARRÊTS',
                  style: TextStyles.displaySmall.copyWith(color: p.label),
                ),
                const SizedBox(height: 2),
                Text(
                  _stops.length > 1
                      ? '${_stops.length} adresses · ordre de passage optimisé'
                      : 'Ajoutez des adresses pour livrer plusieurs clients en une tournée',
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (var i = 0; i < _stops.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              _numberDot('${i + 1}', accent),
                              const SizedBox(width: 14),
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => Navigator.pop(ctx, 'edit:$i'),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _stops[i].place.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyles.headline.copyWith(
                                          color: p.label,
                                        ),
                                      ),
                                      if (_stops[i].name.isNotEmpty ||
                                          _stops[i].place.sublabel.isNotEmpty)
                                        Text(
                                          _stops[i].name.isNotEmpty
                                              ? _stops[i].name
                                              : _stops[i].place.sublabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyles.footnote.copyWith(
                                            color: p.secondaryLabel,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              Pressable(
                                onTap: () {
                                  setState(() => _stops.removeAt(i));
                                  setSheet(() {});
                                  changed = true;
                                  if (_stops.isEmpty)
                                    Navigator.pop(ctx, 'empty');
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(
                                    PhosphorIcons.minusCircle(
                                      PhosphorIconsStyle.fill,
                                    ),
                                    color: p.red,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_stops.length < _maxStops)
                  Pressable(
                    onTap: () => Navigator.pop(ctx, 'add'),
                    child: Container(
                      height: 54,
                      decoration: ShapeDecoration(
                        color: p.accentSoft,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(PhosphorIconsBold.plus, color: accent, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Ajouter un arrêt',
                            style: TextStyles.headline.copyWith(color: accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ink,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Terminé'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'add') return _addStop();
    if (action != null && action.startsWith('edit:'))
      return _addStop(replace: int.parse(action.substring(5)));
    if (action == 'empty' || _stops.isEmpty) return _backToPickup();
    if (changed) _refreshQuote();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final points = _quote == null ? <LatLng>[] : latLngList(_quote!['points']);
    const overlap = 30.0; // la carte passe sous les coins arrondis du panneau

    return Scaffold(
      backgroundColor: p.background,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: -overlap,
                  child: Stack(
                    children: [
                      LetoMap(
                        controller: _map,
                        onMove: _onMove,
                        onMoveEnd: _onMoveEnd,
                        layers: [
                          if (_mode == _Mode.summary && points.isNotEmpty)
                            routeLayer(points),
                          MarkerLayer(
                            markers: [
                              for (final d in _drivers)
                                nearbyDriverMarker(d.point, d.vehicle),
                              if (_mode != _Mode.pickup && _pickup != null)
                                pickupMarker(_pickup!.point),
                              for (var i = 0; i < _stops.length; i++)
                                stopMarker(
                                  context,
                                  _stops[i].place.point,
                                  i + 1,
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (_mode == _Mode.pickup)
                        CenterPin(
                          title: 'Prise en charge',
                          subtitle: _eta == null
                              ? 'Aucun livreur proche'
                              : '~$_eta min',
                          loading: _moving || _lookingUp,
                          place: _centerPlace?.label,
                        ),
                      if (_mode == _Mode.dropoffOnMap)
                        CenterPin(
                          dropoff: true,
                          title: 'Livraison ${_stops.length + 1}',
                          subtitle: 'Livrer ici',
                          loading: _moving,
                          place: _centerPlace?.label,
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            AnimatedSwitcher(
                              duration: Motion.fast,
                              child: _mode == _Mode.pickup
                                  ? MapButton(
                                      PhosphorIconsBold.userCircle,
                                      key: const ValueKey('account'),
                                      onTap: _openAccount,
                                    )
                                  : MapButton(
                                      PhosphorIconsBold.arrowLeft,
                                      key: const ValueKey('back'),
                                      onTap: _backToPickup,
                                    ),
                            ),
                          ],
                        ),
                        AnimatedSwitcher(
                          duration: Motion.medium,
                          child: _active != null && _mode == _Mode.pickup
                              ? Padding(
                                  key: ValueKey(_active!['id']),
                                  padding: const EdgeInsets.only(top: 12),
                                  child: _ActiveBanner(
                                    _active!,
                                    onTap: () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              TrackingScreen(_active!['id']),
                                        ),
                                      );
                                      _loadActive();
                                    },
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_mode != _Mode.summary)
                  Positioned(
                    right: 16,
                    bottom: overlap + 14,
                    child: MapButton(
                      PhosphorIconsBold.navigationArrow,
                      onTap: _locateMe,
                    ),
                  ),
              ],
            ),
          ),
          GlassPanel(
            contentKey: _mode,
            children: switch (_mode) {
              _Mode.pickup => _pickupPanel(p),
              _Mode.dropoffOnMap => _dropoffOnMapPanel(p),
              _Mode.summary => _summaryPanel(p),
            },
          ),
        ],
      ),
    );
  }

  /// Ligne d'adresse (icône, légende, valeur, élément à droite)
  Widget _row({
    required Widget leading,
    required String caption,
    String? value,
    String placeholder = '',
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final p = Palette.of(context);
    final empty = value == null || value.isEmpty;
    return Pressable(
      onTap: onTap,
      pressedScale: 0.985,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 52, child: Center(child: leading)),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedSwitcher(
                duration: Motion.fast,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, ?current],
                ),
                child: Column(
                  key: ValueKey('$caption$value'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!empty)
                      Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyles.subheadline.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                    Text(
                      empty ? placeholder : value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyles.title3.copyWith(
                        fontWeight: FontWeight.w500,
                        color: empty ? p.tertiaryLabel : p.label,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// Carré noir arrondi avec une icône blanche (départ)
  Widget _inkTile(IconData icon) => Container(
    width: 52,
    height: 52,
    decoration: ShapeDecoration(
      color: letoFill,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
      shadows: [
        BoxShadow(
          color: accent.withValues(alpha: 0.35),
          blurRadius: 12,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: Icon(icon, color: Colors.white, size: 26),
  );

  /// Carré violet pâle (livraison)
  Widget _softTile(IconData icon, Palette p) => Container(
    width: 52,
    height: 52,
    decoration: ShapeDecoration(
      color: p.accentSoft,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
    ),
    child: Icon(icon, color: accent, size: 26),
  );

  Widget _numberDot(String label, Color color) => Container(
    width: 30,
    height: 30,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      label,
      style: const TextStyle(
        fontFamily: 'Inter',
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );

  /// Pastille « Arrêts » (comme la ligne de livraison de Yango)
  Widget _stopsPill(Palette p) => Pressable(
    onTap: _stops.isEmpty ? _addStop : _openStopsSheet,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: ShapeDecoration(
        color: p.accentSoft,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsBold.plus, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            _stops.length > 1 ? 'Arrêts · ${_stops.length}' : 'Arrêts',
            style: TextStyles.headline.copyWith(fontSize: 15, color: accent),
          ),
        ],
      ),
    ),
  );

  /// Qui livre : toutes les entreprises ou celle choisie (annuaire, grille tarifaire)
  Widget _companyChip(Palette p) => Pressable(
    onTap: () async {
      final res = await pickCompany(context, _company);
      if (res == null || !mounted) return;
      setState(() => _company = res.$2);
      _loadDrivers();
      _refreshQuote();
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: ShapeDecoration(
        color: p.fill,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _company == null
                ? PhosphorIconsFill.lightning
                : _company.isIndependent
                ? PhosphorIconsFill.moped
                : PhosphorIconsFill.buildings,
            size: 18,
            color: _company.isIndependent ? independentColor : accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _company.isIndependent
                ? Row(
                    children: [
                      Text(
                        'Livré par  ',
                        style: TextStyles.subheadline.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                      const Flexible(child: IndependentBadge()),
                    ],
                  )
                : Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Livré par ',
                          style: TextStyles.subheadline.copyWith(
                            color: p.secondaryLabel,
                          ),
                        ),
                        TextSpan(
                          text: _company?.name ?? 'toutes les entreprises',
                          style: TextStyles.subheadline.copyWith(
                            color: p.label,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          Text(
            'Changer',
            style: TextStyles.subheadline.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _divider(Palette p) => Padding(
    padding: const EdgeInsets.only(left: 64),
    child: Divider(height: 1, thickness: 1, color: p.separator),
  );

  List<Widget> _pickupPanel(Palette p) => [
    Text(
      'ENVOYER UN COLIS',
      style: TextStyles.display.copyWith(color: p.label),
    ),
    const SizedBox(height: 10),
    _row(
      leading: _inkTile(PhosphorIconsFill.package),
      caption: 'Prise en charge',
      value: _moving ? '…' : _centerPlace?.label,
      placeholder: 'Recherche de l’adresse…',
      onTap: _searchPickup,
    ),
    _divider(p),
    _row(
      leading: _softTile(PhosphorIconsFill.flagCheckered, p),
      caption: 'Livraison',
      placeholder: 'Adresse de livraison',
      onTap: _addStop,
      trailing: _stopsPill(p),
    ),
    const SizedBox(height: 8),
  ];

  List<Widget> _dropoffOnMapPanel(Palette p) => [
    Text('OÙ LIVRER ?', style: TextStyles.display.copyWith(color: p.label)),
    const SizedBox(height: 8),
    _row(
      leading: _numberDot('${_stops.length + 1}', accent),
      caption: 'Adresse ${_stops.length + 1}',
      value: _moving ? '…' : _centerPlace?.label,
    ),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: _moving ? null : _confirmDropoffOnMap,
      child: const Text('Valider cette adresse'),
    ),
  ];

  List<Widget> _summaryPanel(Palette p) {
    final offers =
        (_quote?['offers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final selected = offers.where((o) => o['vehicle'] == _vehicle).firstOrNull;
    final route = _quote == null
        ? null
        : '≈ ${_quote!['durationMin']} min · ${km(_quote!['distanceKm'])}';
    return [
      _row(
        leading: _inkTile(PhosphorIconsFill.package),
        caption: 'Prise en charge',
        value: _pickup?.label,
        onTap: _searchPickup,
      ),
      _divider(p),
      _row(
        leading: _softTile(PhosphorIconsFill.flagCheckered, p),
        caption: route ?? 'Calcul de l’itinéraire…',
        value: _stops.length == 1
            ? _stops.first.place.label
            : '${_stops.first.place.label} + ${_stops.length - 1}',
        onTap: _openStopsSheet,
        trailing: _stopsPill(p),
      ),
      const SizedBox(height: 6),
      _companyChip(p),
      if (priceFactors(_quote).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            priceFactors(_quote),
            textAlign: TextAlign.center,
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
        ),
      const SizedBox(height: 10),
      SizedBox(
        height: 134,
        child: AnimatedSwitcher(
          duration: Motion.medium,
          child: _quote == null
              ? const Center(
                  key: ValueKey('loading'),
                  child: CupertinoActivityIndicator(),
                )
              : ListView.separated(
                  key: const ValueKey('offers'),
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  itemCount: offers.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _OfferCard(
                    offer: offers[i],
                    eta: _eta,
                    selected: offers[i]['vehicle'] == _vehicle,
                    onTap: () =>
                        setState(() => _vehicle = offers[i]['vehicle']),
                  ),
                ),
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          // Paiement en espèces
          Container(
            width: 56,
            height: 56,
            decoration: ShapeDecoration(
              color: p.fill,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: PhosphorIcon(
              PhosphorIcons.money(PhosphorIconsStyle.duotone),
              color: p.label,
              size: 30,
              duotoneSecondaryColor: p.green,
              duotoneSecondaryOpacity: 0.55,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: selected == null || _quoting ? null : _continue,
              child: AnimatedSwitcher(
                duration: Motion.fast,
                child: Text(
                  selected == null
                      ? 'Calcul du prix…'
                      : 'Continuer · ${formatMoney(selected['prices']['STANDARD'])}',
                  key: ValueKey(
                    '${selected?['vehicle']}${selected?['prices']?['STANDARD']}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }
}

/// Carte d'offre du carrousel (un engin du devis : Moto, Voiture, Vélo…)
class _OfferCard extends StatelessWidget {
  final Map<String, dynamic> offer;
  final int? eta;
  final bool selected;
  final VoidCallback onTap;
  const _OfferCard({
    required this.offer,
    required this.eta,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final v = offer['vehicle'] as String;
    final ink2 = selected ? p.label : p.secondaryLabel;
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.curve,
        width: 128,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: ShapeDecoration(
          color: selected ? p.fill : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: Motion.medium,
                  width: 62,
                  height: 50,
                  decoration: ShapeDecoration(
                    color: selected ? p.accentSoft : p.fill,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: PhosphorIcon(
                    vehicleDuotoneIcon(v, hint: offer['icon']),
                    size: 36,
                    color: selected ? accent : p.secondaryLabel,
                    duotoneSecondaryColor: selected ? accent : p.secondaryLabel,
                    duotoneSecondaryOpacity: 0.25,
                  ),
                ),
                if (eta != null)
                  Positioned(
                    left: 46,
                    bottom: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: ShapeDecoration(
                        color: p.card,
                        shape: const StadiumBorder(),
                        shadows: const [
                          BoxShadow(
                            color: Color(0x1F000000),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        '${v == 'MOTO' ? eta : eta! + 4} min',
                        style: TextStyles.caption.copyWith(
                          color: p.label,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Spacer(),
            AnimatedDefaultTextStyle(
              duration: Motion.fast,
              style: TextStyles.headline.copyWith(color: ink2, fontSize: 14.5),
              child: Text(
                vehicleName(v, fallback: offer['name'] ?? offer['label']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'dès ',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                  TextSpan(
                    text: formatMoney(offer['prices']['SCHEDULED']),
                    style: TextStyles.price.copyWith(
                      color: ink2,
                      fontSize: 16.5,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bandeau « livraison en cours »
class _ActiveBanner extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback onTap;
  const _ActiveBanner(this.d, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final stops = (d['stops'] as List? ?? []);
    final done = stops.where((s) => s['status'] != 'PENDING').length;
    return Pressable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
        decoration: ShapeDecoration(
          color: ink,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          shadows: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: ShapeDecoration(
                color: letoFill,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              child: const Icon(
                PhosphorIconsFill.moped,
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Livraison en cours · ${statusLabels[d['status']]}',
                    style: TextStyles.subheadline.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    stops.length > 1
                        ? '$done/${stops.length} arrêts traités'
                        : '${d['pickupAddress']} → ${stops.isEmpty ? '' : stops.first['address']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.footnote.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(
              PhosphorIconsBold.caretRight,
              color: Colors.white54,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
