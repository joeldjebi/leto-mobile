import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';
import 'widgets.dart';

/// Suivi d'une livraison côté client (rafraîchi toutes les 5 secondes)
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
  Timer? _timer;
  bool _mapReady = false;

  bool get _finished => ['DELIVERED', 'CANCELLED'].contains(_d?['status']);

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_finished) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await api.getDelivery(widget.id);
      final first = _d == null;
      if (!mounted) return;
      setState(() => _d = d);
      if (first) _fit();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _fit() {
    if (_mapReady && _d != null) fitRoute(_map, pointOf(_d!, 'pickup'), pointOf(_d!, 'dropoff'));
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Annuler la livraison ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Non')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Oui, annuler')),
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
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            LetaMap(
              controller: _map,
              center: a ?? abidjan,
              onReady: () {
                _mapReady = true;
                _fit();
              },
              layers: [
                if (a != null && b != null) routeLine(a, b),
                MarkerLayer(markers: [if (a != null) pin(a), if (b != null) pin(b, dropoff: true)]),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: RoundButton(Icons.arrow_back, onTap: () => Navigator.pop(context)),
              ),
            ),
          ]),
        ),
        BottomPanel(children: d == null ? [const Center(child: CircularProgressIndicator())] : _panel(d)),
      ]),
    );
  }

  List<Widget> _panel(Map<String, dynamic> d) {
    final status = d['status'] as String;
    final title = switch (status) {
      'PENDING' => 'Recherche d’un livreur…',
      'ACCEPTED' => 'Le livreur va récupérer le colis',
      'PICKED_UP' => 'Votre colis est en route',
      'DELIVERED' => 'Colis livré ✅',
      _ => 'Livraison annulée',
    };

    return [
      Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      if (status == 'PENDING') ...[
        const LinearProgressIndicator(minHeight: 4, borderRadius: BorderRadius.all(Radius.circular(2))),
        const SizedBox(height: 10),
        const Text('Votre demande est visible par les livreurs à proximité.', style: TextStyle(color: Colors.grey)),
      ],
      if (status != 'CANCELLED') StatusSteps(status),
      const SizedBox(height: 14),
      if (d['driver'] != null) _driver(d),
      if (!_finished) ...[
        const SizedBox(height: 12),
        _code(d['confirmationCode']),
      ],
      const SizedBox(height: 12),
      AddressTile(d['pickupCommune'], subtitle: d['pickupAddress']),
      AddressTile(d['dropoffCommune'],
          subtitle: '${d['dropoffAddress']} · ${d['recipientName']}', dropoff: true),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Espèces', style: TextStyle(color: Colors.grey)),
        const Spacer(),
        Text(fcfa(d['price']), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ]),
      if (status == 'PENDING') ...[
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _cancel, child: const Text('Annuler la demande')),
      ],
    ];
  }

  Widget _driver(Map<String, dynamic> d) {
    final driver = d['driver'];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: letaOrange,
          child: Text(driver['name'].toString().substring(0, 1).toUpperCase(),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(driver['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(d['company']?['name'] ?? '', style: const TextStyle(color: Colors.grey)),
          ]),
        ),
        Row(children: [
          const Icon(Icons.phone, size: 18, color: letaGreen),
          const SizedBox(width: 4),
          SelectableText(driver['phone'], style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }

  Widget _code(String code) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: letaOrange.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          const Expanded(
            child: Text('Code à donner au destinataire.\nLe livreur le demandera à la remise.',
                style: TextStyle(fontSize: 13)),
          ),
          Text(code, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 4)),
        ]),
      );
}
