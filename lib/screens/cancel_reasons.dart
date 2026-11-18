import 'package:flutter/cupertino.dart';
import '../api.dart';
import 'widgets.dart';

/// Motifs d'annulation gérés par l'admin (back-office > Motifs d'annulation).
/// Rechargés à chaque ouverture ; la dernière liste reçue sert hors connexion.
const _fallback = {
  'client': [
    'Je me suis trompé d’adresse',
    'Le destinataire n’est plus disponible',
    'Le prix ne me convient pas',
  ],
  'driver': [
    'Le destinataire refuse le colis',
    'Le destinataire demande un report',
    'Adresse introuvable ou inaccessible',
  ],
};
final Map<String, List<String>> _cache = {};

Future<List<String>> _reasons(String side) async {
  try {
    final r = await Api.instance.cancelReasons();
    for (final k in ['client', 'driver']) {
      final l = r[k];
      if (l is List && l.isNotEmpty) _cache[k] = l.map((e) => '$e').toList();
    }
  } catch (_) {}
  return _cache[side] ?? _fallback[side]!;
}

/// Feuille de choix du motif. [side] : 'client' ou 'driver'.
/// Renvoie le motif choisi (ou saisi via « Autre motif… »), null si l'utilisateur renonce.
Future<String?> pickCancelReason(
  BuildContext context, {
  required String side,
  required String title,
  String? message,
  String otherPlaceholder = 'Expliquez en quelques mots',
}) async {
  final reasons = await _reasons(side);
  if (!context.mounted) return null;
  const other = '\u0000other';
  final choice = await showActions<String>(
    context,
    title: title,
    message: [?message, 'Choisissez un motif'].join('\n\n'),
    cancelLabel: 'Retour',
    actions: [
      for (final r in reasons) (r, r, false),
      ('Autre motif…', other, false),
    ],
  );
  if (choice == null || !context.mounted) return null;
  if (choice != other) return choice;
  final typed = await prompt(
    context,
    'Autre motif',
    placeholder: otherPlaceholder,
    ok: 'Envoyer',
  );
  if (typed == null || typed.trim().isEmpty) return null;
  return typed.trim();
}
