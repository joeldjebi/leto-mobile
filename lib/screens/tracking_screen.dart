import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import '../realtime.dart';
import 'widgets.dart';

/// Suivi d'une livraison côté client, en temps réel (Socket.IO).
/// Un rafraîchissement REST toutes les 20 s sert de filet de sécurité.
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
  bool _mapReady = false;
  LatLng? _driverPos;
  bool _driverFitted = false;
  void Function()? _unsubscribe;
  List<Map<String, dynamic>> _offers = []; // propositions de prix des livreurs
  Timer? _ticker; // compte à rebours des propositions

  bool get _finished => ['DELIVERED', 'CANCELLED'].contains(_d?['status']);
  bool _active(Map d) => ['ACCEPTED', 'PICKED_UP'].contains(d['status']);

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_finished) _load();
    });
    final rt = Realtime.instance;
    rt.socket.on('driver:location', _onDriverLocation);
    rt.socket.on('delivery:updated', _onDeliveryUpdated);
    rt.socket.on('delivery:offers', _onOffers);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_offers.isEmpty || !mounted) return;
      setState(() => _offers.removeWhere((o) => _secondsLeft(o) <= 0));
    });
    _unsubscribe = rt.onConnected(
      () => rt.socket.emit('delivery:watch', widget.id),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker?.cancel();
    final s = Realtime.instance.socket;
    s.off('delivery:offers', _onOffers);
    s.off('driver:location', _onDriverLocation);
    s.off('delivery:updated', _onDeliveryUpdated);
    s.emit('delivery:unwatch', widget.id);
    _unsubscribe?.call();
    super.dispose();
  }

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
      _loadOffers();
      _fitDriver();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _loadRoute(Map<String, dynamic> d) async {
    final a = pointOf(d, 'pickup'), b = pointOf(d, 'dropoff');
    if (a == null || b == null) return;
    try {
      final r = await api.route(a, b);
      if (!mounted) return;
      setState(() => _route = r);
      if (_mapReady && !_driverFitted) {
        fitPoints(_map, [
          a,
          b,
          ...r.points,
        ], padding: const EdgeInsets.fromLTRB(40, 90, 40, 30));
      }
    } catch (_) {}
  }

  void _fit() {
    if (_mapReady && _d != null) {
      fitPoints(_map, [
        pointOf(_d!, 'pickup'),
        pointOf(_d!, 'dropoff'),
        ...?_route?.points,
      ], padding: const EdgeInsets.fromLTRB(40, 90, 40, 30));
    }
  }

  /// Au premier point GPS du livreur, cadre la carte sur le livreur et sa prochaine étape
  void _fitDriver() {
    if (_driverFitted || !_mapReady || _d == null || _driverPos == null) return;
    final target = _d!['status'] == 'PICKED_UP'
        ? pointOf(_d!, 'dropoff')
        : pointOf(_d!, 'pickup');
    fitPoints(_map, [_driverPos, target]);
    _driverFitted = true;
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Annuler la livraison ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Non'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Oui, annuler'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.cancel(widget.id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final a = d == null ? null : pointOf(d, 'pickup');
    final b = d == null ? null : pointOf(d, 'dropoff');

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                LetoMap(
                  controller: _map,
                  center: a ?? abidjan,
                  onReady: () {
                    _mapReady = true;
                    _fit();
                  },
                  layers: [
                    if (_route != null)
                      routeLayer(_route!.points)
                    else if (a != null && b != null)
                      routeLayer([a, b]),
                    MarkerLayer(
                      markers: [
                        if (a != null) pointMarker(a),
                        if (b != null) pointMarker(b, dropoff: true),
                        if (_driverPos != null && d != null && _active(d))
                          driverMarker(_driverPos!),
                      ],
                    ),
                  ],
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: RoundButton(
                      Icons.arrow_back,
                      onTap: () => Navigator.pop(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.58,
            ),
            child: SingleChildScrollView(
              child: BottomPanel(
                children: d == null
                    ? [const Center(child: CircularProgressIndicator())]
                    : _panel(d),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _panel(Map<String, dynamic> d) {
    final status = d['status'] as String;
    final title = switch (status) {
      'PENDING' => 'Recherche d’un livreur…',
      'ACCEPTED' => 'Le livreur arrive au point de départ',
      'PICKED_UP' => 'Votre colis est en route',
      'DELIVERED' => 'Colis livré',
      _ => 'Livraison annulée',
    };
    final cod = (d['codAmount'] ?? 0) as num;

    return [
      Text(
        title,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      if (status == 'PENDING') ...[
        const LinearProgressIndicator(
          minHeight: 4,
          borderRadius: BorderRadius.all(Radius.circular(2)),
        ),
        const SizedBox(height: 10),
        const Text(
          'Votre demande est visible par les livreurs à proximité.',
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 10),
      ],
      if (status == 'PENDING' && _offers.isNotEmpty) ...[
        const Text(
          'Propositions des livreurs',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
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
        const SizedBox(height: 10),
      ],
      if (status != 'CANCELLED') StatusSteps(status),
      const SizedBox(height: 14),
      if (d['driver'] != null) _driver(d),
      if (_active(d) && _driverPos != null)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.circle, size: 10, color: letoGreen),
              SizedBox(width: 6),
              Text(
                'Position du livreur en direct',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
          ),
        ),
      if (!_finished) ...[
        const SizedBox(height: 12),
        _code(d['confirmationCode']),
      ],
      const SizedBox(height: 12),
      PointLine(
        title: d['pickupAddress'],
        detail: d['pickupDetails'] ?? d['pickupCommune'],
      ),
      PointLine(
        dropoff: true,
        title: d['dropoffAddress'],
        detail: '${d['recipientName']} · ${d['recipientPhone']}',
      ),
      const SizedBox(height: 8),
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
          const CashPill(),
          if (cod > 0) CodBadge(cod),
        ],
      ),
      if (cod > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            d['codRemittedAt'] != null
                ? 'Montant reversé par l’entreprise de livraison'
                : status == 'DELIVERED'
                ? 'Encaissé par le livreur — l’entreprise vous le reversera'
                : 'Le livreur encaissera ${fcfa(cod)} auprès du destinataire',
            style: const TextStyle(color: Colors.black54, fontSize: 13),
          ),
        ),
      const SizedBox(height: 10),
      Row(
        children: [
          Text(
            d['distanceKm'] != null ? km(d['distanceKm']) : '',
            style: const TextStyle(color: Colors.grey),
          ),
          const Spacer(),
          const Text('Course ', style: TextStyle(color: Colors.grey)),
          Text(
            fcfa(d['price']),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      if (status == 'PENDING') ...[
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _cancel,
          child: const Text('Annuler la demande'),
        ),
      ],
    ];
  }

  Widget _driver(Map<String, dynamic> d) {
    final driver = d['driver'];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Avatar(driver['name'], radius: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  driver['name'],
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  d['company']?['name'] ?? '',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
          const Icon(Icons.phone, size: 18, color: letoGreen),
          const SizedBox(width: 4),
          SelectableText(
            driver['phone'],
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _code(String code) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: letoOrange.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Code à donner au destinataire.\nLe livreur le demandera à la remise.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        Text(
          code,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
          ),
        ),
      ],
    ),
  );
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
    final mm = (secondsLeft ~/ 60).toString();
    final ss = (secondsLeft % 60).toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: letoOrange.withValues(alpha: 0.4)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(offer['driver']['name'], radius: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer['driver']['name'],
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      [
                        if (offer['company'] != null) offer['company']['name'],
                        if (offer['etaMin'] != null)
                          'arrive en ~${offer['etaMin']} min',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
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
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '+${fcfa(offer['price'] - original)}',
                    style: const TextStyle(
                      color: letoOrange,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
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
                style: const TextStyle(
                  color: Colors.grey,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              TextButton(onPressed: onDecline, child: const Text('Refuser')),
              const SizedBox(width: 6),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(130, 44)),
                onPressed: onAccept,
                child: const Text('Accepter'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
