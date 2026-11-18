import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../countries.dart';
import '../main.dart';
import 'widgets.dart';

/// Message envoyé au destinataire : code de livraison et montant à préparer
String shareMessage(Map<String, dynamic> d, Map<String, dynamic> stop) {
  final sender = Api.instance.user?['name'] ?? 'votre expéditeur';
  final cod = (stop['codAmount'] ?? 0) as num;
  return [
    'Bonjour ${stop['recipientName']},',
    'Votre colis de $sender arrive avec LETO.',
    '',
    'Code de livraison : ${stop['confirmationCode']}',
    'Donnez ce code au livreur à la remise du colis.',
    if (cod > 0)
      'Montant à payer à la livraison : ${formatMoney(cod, d['currency'])} (espèces)',
    '',
    'Adresse : ${stop['address']}',
    if (trackingUrl(d) != null) 'Suivre la livraison : ${trackingUrl(d)}',
  ].join('\n');
}

/// WhatsApp directement au numéro du destinataire (E.164 sans « + »), sinon partage du système
Future<void> shareToWhatsApp(
  BuildContext context,
  Map<String, dynamic> d,
  Map<String, dynamic> stop,
) async {
  final e164 = parseAnyPhone(stop['recipientPhone']);
  if (e164 == null) return shareCode(context, d, stop);
  final uri = Uri.parse(
    'https://wa.me/${e164.substring(1)}?text=${Uri.encodeComponent(shareMessage(d, stop))}',
  );
  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (!ok && context.mounted) await shareCode(context, d, stop);
}

Future<void> shareCode(
  BuildContext context,
  Map<String, dynamic> d,
  Map<String, dynamic> stop,
) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      text: shareMessage(d, stop),
      subject: 'Votre code de livraison LETO',
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

/// Feuille affichée après la commande : un bouton de partage par destinataire
Future<void> showShareCodes(BuildContext context, Map<String, dynamic> d) {
  final stops = (d['stops'] as List).cast<Map<String, dynamic>>();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Palette.of(context).background,
    shape: const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final p = Palette.of(ctx);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: stops.length > 2 ? 0.85 : 0.6,
        maxChildSize: 0.95,
        builder: (_, scroll) => ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 8),
            const Grabber(),
            const SizedBox(height: 16),
            Icon(CupertinoIcons.checkmark_seal_fill, color: p.green, size: 52),
            const SizedBox(height: 8),
            Text(
              'Commande envoyée',
              textAlign: TextAlign.center,
              style: TextStyles.title2.copyWith(color: p.label),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 6, 32, 20),
              child: Text(
                stops.length > 1
                    ? 'Envoyez à chaque destinataire son code de livraison. Le livreur le demandera à la remise.'
                    : 'Envoyez le code de livraison à votre destinataire. Le livreur le demandera à la remise.',
                textAlign: TextAlign.center,
                style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
              ),
            ),
            InsetGroup(
              children: [for (final s in stops) _ShareRow(d: d, stop: s)],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Suivre la livraison'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
}

class _ShareRow extends StatelessWidget {
  final Map<String, dynamic> d;
  final Map<String, dynamic> stop;
  const _ShareRow({required this.d, required this.stop});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
            ),
            child: Text(
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
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                Text(
                  'Code ${stop['confirmationCode']}',
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          _CircleAction(
            icon: CupertinoIcons.chat_bubble_fill,
            color: const Color(0xFF25D366),
            tooltip: 'WhatsApp',
            onTap: () => shareToWhatsApp(context, d, stop),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (ctx) => _CircleAction(
              icon: CupertinoIcons.share,
              color: p.blue,
              tooltip: 'Partager',
              onTap: () => shareCode(ctx, d, stop),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _CircleAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: () {
        hapticTap();
        onTap();
      },
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 19),
      ),
    ),
  );
}
