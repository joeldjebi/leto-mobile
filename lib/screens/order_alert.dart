import 'dart:async';
import 'dart:collection';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../notifications.dart';
import '../theme.dart';
import 'widgets.dart';

/// Navigateur racine : l'alerte « nouvelle commande » s'affiche au-dessus de tous les écrans
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Alerte plein écran « Nouvelle course » chez le livreur, quel que soit l'écran ouvert :
/// résumé de la course, compte à rebours, son répété, Accepter / Refuser.
/// Les commandes arrivées en même temps attendent leur tour (une alerte à la fois).
class OrderAlert {
  OrderAlert._();
  static final instance = OrderAlert._();

  final _queue = Queue<Map<String, dynamic>>();
  final _handled = <String>{};
  OverlayEntry? _entry;
  Map<String, dynamic>? _current;
  Timer? _ring;

  /// Course acceptée depuis l'alerte (l'accueil livreur recharge et ouvre « En cours »)
  final accepted = ValueNotifier<String?>(null);

  /// Course à ouvrir en détail (« Voir le détail »)
  final open = ValueNotifier<String?>(null);

  bool get visible => _entry != null;

  /// Nouvelle commande reçue par le temps réel (payload `notify` de type NEW_ORDER)
  void add(Map<String, dynamic> p) {
    final id = p['deliveryId'] as String?;
    if (id == null || _handled.contains(id) || _current?['deliveryId'] == id) {
      return;
    }
    if (_queue.any((x) => x['deliveryId'] == id)) return;
    _queue.add(p);
    _next();
  }

  /// La course n'est plus disponible (prise par un autre livreur, annulée) : alerte retirée
  void remove(String deliveryId) {
    _queue.removeWhere((x) => x['deliveryId'] == deliveryId);
    if (_current?['deliveryId'] == deliveryId) _close(handled: false);
  }

  /// Ne garde que les courses encore disponibles (après un rechargement de la liste)
  void keepOnly(Iterable<String> availableIds) {
    final ids = availableIds.toSet();
    _queue.removeWhere((x) => !ids.contains(x['deliveryId']));
    final cur = _current?['deliveryId'];
    if (cur != null && !ids.contains(cur)) _close(handled: false);
  }

  /// Déconnexion : plus aucune alerte
  void reset() {
    _queue.clear();
    _close(handled: false);
    _handled.clear();
  }

  static DateTime? _expiry(Map p) =>
      DateTime.tryParse((p['expiresAt'] ?? '') as String)?.toLocal();

  void _next() {
    if (_entry != null) return;
    // Alertes expirées pendant que l'app était en arrière-plan : ignorées
    while (_queue.isNotEmpty) {
      final e = _expiry(_queue.first);
      if (e == null ||
          e.isAfter(DateTime.now().add(const Duration(seconds: 3))))
        break;
      _queue.removeFirst();
    }
    if (_queue.isEmpty) return;
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _current = _queue.removeFirst();
    final p = _current!;
    _entry = OverlayEntry(
      builder: (_) => _OrderAlertView(
        payload: p,
        onAccept: () => _accept(p),
        onDecline: () => _close(handled: true),
        onDetails: () {
          final id = p['deliveryId'] as String;
          _close(handled: true);
          open.value = null;
          open.value = id;
        },
        onTimeout: () => _close(handled: true),
      ),
    );
    overlay.insert(_entry!);
    _startRinging((p['sound']?['id'] as String?) ?? builtinSounds.first);
    hapticSuccess();
  }

  void _startRinging(String soundId) {
    _ring?.cancel();
    LetoNotifier.instance.play(soundId);
    // Son répété tant que l'alerte est affichée (les sons LETO durent environ 1 s)
    _ring = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      LetoNotifier.instance.play(soundId);
      hapticTap();
    });
  }

  Future<String?> _accept(Map<String, dynamic> p) async {
    final id = p['deliveryId'] as String;
    try {
      await Api.instance.accept(id);
      _close(handled: true);
      hapticSuccess();
      accepted.value = null;
      accepted.value = id;
      return null;
    } catch (e) {
      _ring?.cancel();
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  void _close({required bool handled}) {
    _ring?.cancel();
    _ring = null;
    LetoNotifier.instance.stopSound();
    final id = _current?['deliveryId'] as String?;
    if (handled && id != null) _handled.add(id);
    _entry?.remove();
    _entry = null;
    _current = null;
    // Alerte suivante, après une courte pause
    if (_queue.isNotEmpty) {
      Timer(const Duration(milliseconds: 400), _next);
    }
  }
}

class _OrderAlertView extends StatefulWidget {
  final Map<String, dynamic> payload;
  final Future<String?> Function() onAccept;
  final VoidCallback onDecline;
  final VoidCallback onDetails;
  final VoidCallback onTimeout;
  const _OrderAlertView({
    required this.payload,
    required this.onAccept,
    required this.onDecline,
    required this.onDetails,
    required this.onTimeout,
  });

  @override
  State<_OrderAlertView> createState() => _OrderAlertViewState();
}

class _OrderAlertViewState extends State<_OrderAlertView>
    with SingleTickerProviderStateMixin {
  late final DateTime _end;
  late final int _total;
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: Motion.medium,
  )..forward();
  Timer? _tick;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final exp = OrderAlert._expiry(widget.payload);
    final now = DateTime.now();
    _end = exp != null && exp.isAfter(now)
        ? exp
        : now.add(const Duration(seconds: 30));
    _total = _end.difference(now).inSeconds.clamp(5, 120);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(_end) && !_busy) {
        _tick?.cancel();
        widget.onTimeout();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _in.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onAccept();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final o = ((widget.payload['order'] ?? {}) as Map).cast<String, dynamic>();
    final match = widget.payload['match'] as Map?;
    final busy = (widget.payload['busy'] ?? 0) as num;
    final left =
        _end.difference(DateTime.now()).inMilliseconds.clamp(0, 1 << 30) / 1000;
    final secs = left.ceil();
    final stops = (o['stops'] ?? 1) as num;
    final cod = (o['cod'] ?? 0) as num;
    final fromMe = o['fromMeKm'] as num?;

    final (badge, badgeColor, badgeIcon) = switch (match?['kind']) {
      'ROUTE' => ('Sur votre trajet', p.green, CupertinoIcons.arrow_branch),
      'NEARBY' => (
        'À ${km(fromMe ?? match?['km'] ?? 0)} de vous',
        p.blue,
        CupertinoIcons.location_fill,
      ),
      _ => (
        fromMe == null ? 'Nouvelle course' : 'À ${km(fromMe)} de vous',
        accent,
        CupertinoIcons.location_fill,
      ),
    };

    Widget chip(IconData icon, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: p.secondaryLabel),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyles.footnote.copyWith(
              color: p.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    Widget leg(String letter, Color color, String? commune, String? address) =>
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(
                letter,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    commune ?? address ?? '—',
                    style: TextStyles.headline.copyWith(color: p.label),
                  ),
                  if (commune != null && address != null && address.isNotEmpty)
                    Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyles.footnote.copyWith(
                        color: p.secondaryLabel,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );

    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _in,
        child: Stack(
          children: [
            // Fond assombri : l'alerte ne se ferme pas d'un toucher à côté (évite les refus involontaires)
            const Positioned.fill(child: ColoredBox(color: Color(0x99000000))),
            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.25),
                  end: Offset.zero,
                ).animate(CurvedAnimation(parent: _in, curve: Motion.curve)),
                child: SafeArea(
                  minimum: const EdgeInsets.all(12),
                  child: Container(
                    key: const Key('order-alert'),
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 520),
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(color: Color(0x55000000), blurRadius: 30),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(badgeIcon, size: 14, color: badgeColor),
                                  const SizedBox(width: 5),
                                  Text(
                                    badge,
                                    style: TextStyles.footnote.copyWith(
                                      color: badgeColor,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    value: (left / _total).clamp(0.0, 1.0),
                                    strokeWidth: 4,
                                    backgroundColor: p.fill,
                                    color: secs <= 5 ? p.red : accent,
                                  ),
                                  Text(
                                    '$secs',
                                    style: TextStyles.headline.copyWith(
                                      color: secs <= 5 ? p.red : p.label,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Nouvelle course',
                          style: TextStyles.subheadline.copyWith(
                            color: p.secondaryLabel,
                          ),
                        ),
                        Text(
                          formatMoney(o['price'], o['currency'] as String?),
                          style: TextStyles.display.copyWith(color: p.label),
                        ),
                        if (busy > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'En plus de ${busy == 1 ? 'votre course en cours' : 'vos $busy courses en cours'}',
                              style: TextStyles.footnote.copyWith(
                                color: p.secondaryLabel,
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        leg(
                          'A',
                          p.green,
                          o['pickupCommune'] as String?,
                          o['pickupAddress'] as String?,
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 11),
                            child: Container(
                              width: 2,
                              height: 14,
                              color: p.separator,
                            ),
                          ),
                        ),
                        leg(
                          stops > 1 ? '$stops' : 'B',
                          p.red,
                          o['dropCommune'] as String?,
                          stops > 1
                              ? '$stops arrêts'
                              : o['dropAddress'] as String?,
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (o['distanceKm'] != null)
                              chip(
                                CupertinoIcons.map,
                                km(o['distanceKm'] as num),
                              ),
                            if (o['durationMin'] != null)
                              chip(
                                CupertinoIcons.time,
                                '${o['durationMin']} min',
                              ),
                            if (o['vehicleType'] != null)
                              chip(
                                CupertinoIcons.cube_box,
                                vehicleLabels[o['vehicleType']] ??
                                    '${o['vehicleType']}',
                              ),
                            if (cod > 0)
                              chip(
                                CupertinoIcons.money_dollar_circle,
                                'Encaisser ${formatMoney(cod, o['currency'] as String?)}',
                              ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyles.footnote.copyWith(color: p.red),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: SizedBox(
                                height: 56,
                                child: OutlinedButton(
                                  key: const Key('order-alert-decline'),
                                  onPressed: _busy ? null : widget.onDecline,
                                  style: OutlinedButton.styleFrom(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: Text(
                                    _error != null ? 'Fermer' : 'Refuser',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 3,
                              child: SizedBox(
                                height: 56,
                                child: FilledButton(
                                  key: const Key('order-alert-accept'),
                                  onPressed: _busy || _error != null
                                      ? null
                                      : _accept,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: p.green,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: _busy
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          'Accepter',
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        TextButton(
                          onPressed: _busy ? null : widget.onDetails,
                          child: const Text(
                            'Voir le détail ou proposer un prix',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
