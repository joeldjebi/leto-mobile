import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../countries.dart';
import '../labels.dart';
import '../main.dart';
import '../theme.dart';
import 'widgets.dart';

// ============================================================================
// Suivi d'une course côté client : briques de l'écran
// ============================================================================

/// Frise en 5 étapes : commandée → livreur en route → colis récupéré → en livraison → livré
class DeliveryProgress extends StatelessWidget {
  final String status;
  final String? vehicle;
  const DeliveryProgress(this.status, {super.key, this.vehicle});

  /// Nombre d'étapes franchies (la dernière franchie est l'étape en cours)
  int get _reached => switch (status) {
    'PENDING' => 1,
    'ACCEPTED' => 2,
    'PICKED_UP' => 4,
    'DELIVERED' => 5,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final steps = <(IconData, String)>[
      (PhosphorIconsBold.check, 'Commandée'),
      (vehicleIcon(vehicle), 'Livreur en route'),
      (PhosphorIconsFill.package, 'Colis récupéré'),
      (vehicleIcon(vehicle), 'En livraison'),
      (PhosphorIconsFill.flagCheckered, 'Livré'),
    ];
    final reached = _reached;
    return Semantics(
      label:
          'Étape ${reached.clamp(1, 5)} sur 5 : ${steps[(reached - 1).clamp(0, 4)].$2}',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0)
              Expanded(
                child: AnimatedContainer(
                  duration: Motion.medium,
                  height: 4,
                  color: i < reached ? accent : p.fill,
                ),
              ),
            AnimatedContainer(
              duration: Motion.medium,
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < reached ? accent : p.fill,
              ),
              child: Icon(
                steps[i].$1,
                size: 22,
                color: i < reached ? Colors.white : p.tertiaryLabel,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Action ronde avec son libellé (Appeler, Partager…)
class RoundAction extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  const RoundAction({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: onTap != null,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressedScale: 0.92,
        child: SizedBox(
          width: 78,
          child: Column(
            children: [
              SizedBox(width: 60, height: 60, child: icon),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyles.caption.copyWith(color: p.secondaryLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icône d'une action ronde (fond gris)
class RoundIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;
  const RoundIcon(this.icon, {super.key, this.color});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: p.fill),
      child: Icon(icon, size: 24, color: color ?? p.label),
    );
  }
}

/// Photo du livreur avec sa note moyenne en pastille
class DriverPhoto extends StatelessWidget {
  final Map driver;
  const DriverPhoto(this.driver, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rating = ratingOf(driver);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Avatar(driver['name'] ?? '?', radius: 30, photo: driver['avatarUrl']),
        if (rating != null)
          Positioned(
            right: -10,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(color: Color(0x22000000), blurRadius: 6),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PhosphorIconsFill.star, size: 11, color: p.yellow),
                  const SizedBox(width: 2),
                  Text(
                    rating.toStringAsFixed(1),
                    style: TextStyles.caption.copyWith(
                      color: p.label,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Note moyenne affichée seulement à partir de 3 notes (sinon elle ne veut rien dire)
double? ratingOf(Map? driver) {
  if (driver == null) return null;
  final n = (driver['ratingCount'] as num?) ?? 0;
  final avg = driver['ratingAvg'] as num?;
  return n >= 3 && avg != null ? avg.toDouble() : null;
}

/// Engin + immatriculation, en haut à droite du titre
class VehiclePlate extends StatelessWidget {
  final String? vehicle;
  final String? plate;
  const VehiclePlate({super.key, this.vehicle, this.plate});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (plate != null && plate!.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: p.card,
              border: Border.all(color: p.separator, width: 1.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              plate!,
              style: TextStyles.footnote.copyWith(
                color: p.label,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        const SizedBox(height: 6),
        Icon(vehicleIcon(vehicle), size: 34, color: accent),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Notation après la livraison
// ---------------------------------------------------------------------------

/// Compliments (4–5 étoiles) et points à améliorer (1–3 étoiles), codes identiques à l'API
const _praise = [
  ('FAST', 'Très rapide', PhosphorIconsFill.lightning),
  ('POLITE', 'Livreur poli', PhosphorIconsFill.thumbsUp),
  ('CAREFUL', 'Colis soigné', PhosphorIconsFill.package),
  ('ABOVE', 'Au-delà des attentes', PhosphorIconsBold.sparkle),
];
const _issues = [
  ('LATE', 'En retard', PhosphorIconsFill.clock),
  ('RUDE', 'Peu aimable', PhosphorIconsFill.thumbsDown),
  ('DAMAGED', 'Colis abîmé', PhosphorIconsBold.package),
  ('UNREACHABLE', 'Injoignable', PhosphorIconsFill.phoneSlash),
];

String ratingTagLabel(String code) =>
    [..._praise, ..._issues].where((t) => t.$1 == code).firstOrNull?.$2 ?? code;

/// Carte « Comment s'est passée la livraison ? » : étoiles, compliments, commentaire
class RatingCard extends StatefulWidget {
  final Map<String, dynamic> delivery;
  final ValueChanged<Map<String, dynamic>> onRated;
  const RatingCard({super.key, required this.delivery, required this.onRated});
  @override
  State<RatingCard> createState() => _RatingCardState();
}

class _RatingCardState extends State<RatingCard> {
  int _stars = 0;
  final _tags = <String>{};
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final d = await Api.instance.rate(
        widget.delivery['id'],
        stars: _stars,
        tags: _tags.toList(),
        comment: _comment.text,
      );
      hapticSuccess();
      if (mounted) showInfo(context, 'Merci pour votre avis !');
      widget.onRated(d);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = widget.delivery;
    final given = d['rating'] as int?;
    final tags = _stars >= 4 ? _praise : _issues;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      child: Column(
        children: [
          Text(
            given != null
                ? 'Votre avis'
                : 'Comment s’est passée la livraison ?',
            textAlign: TextAlign.center,
            style: TextStyles.headline.copyWith(color: p.label),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                Semantics(
                  button: given == null,
                  label: '$i étoile${i > 1 ? 's' : ''}',
                  selected: (given ?? _stars) >= i,
                  child: GestureDetector(
                    onTap: given != null
                        ? null
                        : () {
                            hapticTap();
                            setState(() {
                              if ((_stars >= 4) != (i >= 4)) _tags.clear();
                              _stars = i;
                            });
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: AnimatedScale(
                        scale: (given ?? _stars) >= i ? 1.08 : 1,
                        duration: Motion.fast,
                        child: Icon(
                          (given ?? _stars) >= i
                              ? PhosphorIconsFill.star
                              : PhosphorIconsBold.star,
                          size: 40,
                          color: (given ?? _stars) >= i
                              ? p.yellow
                              : p.tertiaryLabel,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (given != null) ...[
            if ((d['ratingTags'] as List?)?.isNotEmpty == true) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  for (final t in (d['ratingTags'] as List).cast<String>())
                    Pill(ratingTagLabel(t), color: accent),
                ],
              ),
            ],
            if (d['ratingComment'] != null) ...[
              const SizedBox(height: 8),
              Text(
                '« ${d['ratingComment']} »',
                textAlign: TextAlign.center,
                style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
              ),
            ],
          ] else if (_stars > 0) ...[
            const SizedBox(height: 14),
            Text(
              _stars >= 4
                  ? 'Qu’avez-vous apprécié ?'
                  : 'Qu’est-ce qui n’a pas été ?',
              style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final (code, label, icon) in tags)
                  Expanded(
                    child: _TagChoice(
                      icon: icon,
                      label: label,
                      selected: _tags.contains(code),
                      onTap: () => setState(
                        () => _tags.contains(code)
                            ? _tags.remove(code)
                            : _tags.add(code),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: _comment,
              placeholder: 'Un commentaire ? (facultatif)',
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              padding: const EdgeInsets.all(12),
              style: TextStyles.body.copyWith(color: p.label),
              decoration: BoxDecoration(
                color: p.fill,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const CupertinoActivityIndicator(color: Colors.white)
                    : const Text('Envoyer mon avis'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TagChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TagChoice({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: () {
          hapticTap();
          onTap();
        },
        child: Column(
          children: [
            AnimatedContainer(
              duration: Motion.fast,
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? accent : p.fill,
              ),
              child: Icon(
                icon,
                size: 24,
                color: selected ? Colors.white : p.secondaryLabel,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyles.caption.copyWith(
                color: selected ? p.label : p.secondaryLabel,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Détails de la commande
// ---------------------------------------------------------------------------

String _dateTime(String? iso) {
  final t = DateTime.tryParse(iso ?? '')?.toLocal();
  if (t == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}/${t.year} à ${two(t.hour)}:${two(t.minute)}';
}

/// Feuille « Détails de la commande » : service, prix, paiement, livreur, entreprise
Future<void> showOrderDetails(BuildContext context, Map<String, dynamic> d) {
  final driver = d['driver'] as Map?;
  final company = d['company'] as Map?;
  final independent = company?['independent'] == true;
  // LI : entreprise de rattachement, responsable du livreur
  final affiliate = d['affiliateCompany'] as Map?;
  final responsible = independent ? affiliate : company;
  final active = ['ACCEPTED', 'PICKED_UP'].contains(d['status']);
  final companyPhone = responsible?['phone'] as String?;
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Palette.of(context).background,
    shape: const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const Center(child: Grabber()),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'Détails de la commande',
                  style: TextStyles.title2.copyWith(color: p.label),
                ),
              ),
              InsetGroup(
                children: [
                  GroupRow(
                    title: 'Commandée le',
                    value: _dateTime(d['createdAt']),
                  ),
                  GroupRow(
                    title: 'Service',
                    value: [
                      vehicleLabels[d['vehicleType']],
                      speedLabels[d['speed']],
                    ].whereType<String>().join(' · '),
                  ),
                  if (d['distanceKm'] != null)
                    GroupRow(title: 'Distance', value: km(d['distanceKm'])),
                  GroupRow(
                    title: 'Prix',
                    value: formatMoney(d['price'], d['currency']),
                  ),
                  GroupRow(
                    title: 'Paiement de la livraison',
                    value: d['feePaidBy'] == 'RECIPIENT'
                        ? 'Destinataire, en espèces'
                        : 'Espèces, au départ',
                  ),
                  if (d['deliveredAt'] != null)
                    GroupRow(
                      title: 'Livrée le',
                      value: _dateTime(d['deliveredAt']),
                    ),
                ],
              ),
              if (driver != null)
                InsetGroup(
                  header: 'Livraison assurée par',
                  children: [
                    GroupRow(
                      leading: Avatar(
                        driver['name'] ?? '?',
                        radius: 18,
                        photo: driver['avatarUrl'],
                      ),
                      title: driver['name'] ?? '',
                      subtitle: [
                        vehicleLabels[driver['vehicleType']],
                        if ((driver['plate'] ?? '').toString().isNotEmpty)
                          driver['plate'],
                        if (ratingOf(driver) != null)
                          '★ ${ratingOf(driver)!.toStringAsFixed(1)}',
                      ].whereType<String>().join(' · '),
                    ),
                    if (company != null)
                      GroupRow(
                        title: independent
                            ? affiliate != null
                                  ? 'Livreur indépendant · ${affiliate['name']}'
                                  : 'Livreur indépendant'
                            : company['name'] ?? '',
                        subtitle: independent
                            ? affiliate != null
                                  ? 'Vérifié par LETO · ${affiliate['name']} en est responsable'
                                  : 'Vérifié par LETO'
                            : 'Entreprise de livraison',
                        // Problème avec le livreur : appeler son entreprise pendant la course
                        trailing: active && (companyPhone ?? '').isNotEmpty
                            ? CupertinoButton(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                onPressed: () => callPhone(ctx, companyPhone),
                                child: Icon(
                                  PhosphorIconsFill.phone,
                                  color: p.green,
                                  size: 22,
                                  semanticLabel: 'Appeler l’entreprise',
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  'Réf. ${(d['id'] as String).substring(0, 8).toUpperCase()}',
                  style: TextStyles.footnote.copyWith(color: p.tertiaryLabel),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Appeler un numéro (livreur, destinataire)
Future<void> callPhone(BuildContext context, String? phone) async {
  if (phone == null || phone.isEmpty) return;
  hapticTap();
  if (!await launchUrl(telUri(phone)) && context.mounted) {
    showError(
      context,
      'Impossible de lancer l’appel vers ${formatPhone(phone)}',
    );
  }
}
