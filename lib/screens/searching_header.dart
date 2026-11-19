import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// En-tête de la recherche d'un livreur (suivi d'une commande en attente) :
/// indicateur animé, temps écoulé, livreurs autour, expiration de la commande, prix et explication.
class SearchingHeader extends StatefulWidget {
  final DateTime createdAt;
  final int nearby;

  /// Délai d'expiration fixé par l'admin (minutes, 0 = jamais)
  final int expiryMin;
  final String price;

  /// Commande adressée à une entreprise de livraison précise
  final bool targeted;

  const SearchingHeader({
    super.key,
    required this.createdAt,
    required this.nearby,
    required this.expiryMin,
    required this.price,
    required this.targeted,
  });

  @override
  State<SearchingHeader> createState() => _SearchingHeaderState();
}

class _SearchingHeaderState extends State<SearchingHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();
  // Compteur : rafraîchi chaque seconde
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _tick; // démarre le compteur
  }

  @override
  void dispose() {
    _tick.cancel();
    _pulse.dispose();
    super.dispose();
  }

  static String _duration(Duration x) {
    final m = x.inMinutes, s = x.inSeconds % 60;
    return m > 0 ? '$m min ${s.toString().padLeft(2, '0')} s' : '$s s';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    var elapsed = DateTime.now().difference(widget.createdAt);
    if (elapsed.isNegative) elapsed = Duration.zero;
    final left = widget.expiryMin > 0
        ? Duration(minutes: widget.expiryMin) - elapsed
        : null;
    final n = widget.nearby;
    final message = n == 0
        ? 'Aucun livreur en ligne près du départ pour l’instant. Votre demande reste visible : le premier qui se connecte la reçoit.'
        : widget.targeted
        ? 'Votre demande est envoyée aux livreurs de l’entreprise choisie. Le premier qui accepte prend la course.'
        : 'Votre demande est envoyée aux livreurs les plus proches. Ils peuvent l’accepter ou vous proposer un prix.';
    final reduce = MediaQuery.of(context).disableAnimations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, _) => Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!reduce)
                      for (final k in const [0.0, 0.5])
                        Builder(
                          builder: (_) {
                            final t = (_pulse.value + k) % 1;
                            return Container(
                              width: 30 + 22 * t,
                              height: 30 + 22 * t,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withValues(alpha: 0.22 * (1 - t)),
                              ),
                            );
                          },
                        ),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: letoGradient,
                      ),
                      child: const Icon(
                        CupertinoIcons.search,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recherche d’un livreur',
                    style: TextStyles.title2.copyWith(color: p.label),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Depuis ${_duration(elapsed)}',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
              icon: Icons.two_wheeler,
              text: n == 0
                  ? 'Aucun livreur autour'
                  : '$n livreur${n > 1 ? 's' : ''} à proximité',
              color: n == 0 ? p.yellow : p.green,
            ),
            if (left != null && left > Duration.zero)
              _Chip(
                icon: CupertinoIcons.timer,
                text: 'Expire dans ${left.inMinutes + 1} min',
                color: accent,
              ),
            _Chip(
              icon: CupertinoIcons.tag_fill,
              text: widget.price,
              color: accent,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          message,
          style: TextStyles.footnote.copyWith(
            color: p.secondaryLabel,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Chip({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.subheadline.copyWith(
                color: p.label,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
