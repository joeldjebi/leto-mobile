import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../countries.dart';
import '../theme.dart';
import 'widgets.dart' show Grabber, hapticTap;

/// Saisie d'un numéro : chiffres nationaux dans [text], pays choisi dans [country].
/// [e164] donne la valeur à envoyer à l'API (« +2250701020304 »), null si invalide.
/// Drapeau d'un pays en image (flagcdn.com, mise en cache par l'app) ; à défaut, ses initiales ISO.
/// Les emojis drapeaux ne s'affichent pas sur tous les appareils, d'où l'image.
class CountryFlag extends StatelessWidget {
  final String iso;
  final double height;
  const CountryFlag({super.key, required this.iso, this.height = 16});

  @override
  Widget build(BuildContext context) {
    final w = height * 4 / 3;
    final code = iso.toLowerCase();
    Widget fallback() => Container(
      width: w,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Palette.of(context).fill,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        iso.toUpperCase(),
        style: TextStyle(
          fontSize: height * 0.55,
          fontWeight: FontWeight.w700,
          color: Palette.of(context).secondaryLabel,
        ),
      ),
    );
    if (!RegExp(r'^[a-z]{2}$').hasMatch(code)) return fallback();
    return Semantics(
      label: 'Drapeau ${iso.toUpperCase()}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Image.network(
          'https://flagcdn.com/h40/$code.png',
          width: w,
          height: height,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => fallback(),
          frameBuilder: (_, child, frame, sync) =>
              frame == null && !sync ? fallback() : child,
        ),
      ),
    );
  }
}

class PhoneController extends TextEditingController {
  PhoneController([String? initial]) {
    setPhone(initial);
  }

  Country? _country;

  /// Pays choisi (par défaut : celui où LETO livre)
  Country get country => _country ?? Countries.instance.operating;
  set country(Country c) {
    if (c == _country) return;
    _country = c;
    notifyListeners();
  }

  /// Chiffres nationaux (préfixe national retiré)
  String get national => nationalDigits(country, text);

  /// Numéro international, null si vide ou invalide
  String? get e164 => toE164(country, text);

  bool get isBlank => text.trim().isEmpty;

  /// Message d'erreur (français) ou null
  String? validate({bool required = true}) =>
      validatePhone(country, text, required: required);

  /// Remplit le champ depuis un numéro E.164 (ou un ancien format / un numéro du répertoire)
  void setPhone(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) {
      text = '';
      return;
    }
    final e164 = parseAnyPhone(raw);
    final c = Countries.instance.byE164(e164);
    if (e164 != null && c != null) {
      _country = c;
      text = e164.substring(1 + c.dialCode.length);
    } else {
      text = raw;
    }
  }
}

/// Champ de téléphone intégré à une liste groupée (même rendu que [GroupField]) :
/// indicatif du pays (drapeau + « +225 ») à gauche, choisi dans une feuille si plusieurs pays sont actifs.
class PhoneField extends StatelessWidget {
  final PhoneController controller;

  /// Par défaut : l'exemple du pays (« 07 01 02 03 04 »)
  final String? placeholder;

  /// Validation dans un [Form] : obligatoire / facultatif
  final bool validate;
  final bool required;

  /// Valeur E.164 à chaque changement (null si incomplète ou invalide)
  final ValueChanged<String?>? onChanged;
  final Widget? trailing;
  final bool autofocus;

  const PhoneField({
    super.key,
    required this.controller,
    this.placeholder,
    this.validate = false,
    this.required = true,
    this.onChanged,
    this.trailing,
    this.autofocus = false,
  });

  void _changed(String value) {
    // Numéro international collé (+225…, 00225…) : bon pays, chiffres nationaux
    final v = value.trim();
    if (v.startsWith('+') || v.startsWith('00')) {
      final e164 = parseAnyPhone(v);
      if (e164 != null) {
        controller.setPhone(e164);
        controller.selection = TextSelection.collapsed(
          offset: controller.text.length,
        );
      }
    }
    onChanged?.call(controller.e164);
  }

  Future<void> _pick(BuildContext context) async {
    hapticTap();
    final c = await showCountryPicker(context, selected: controller.country);
    if (c == null) return;
    controller.country = c;
    onChanged?.call(controller.e164);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Countries.instance, controller]),
      builder: (context, _) {
        final countries = Countries.instance.list;
        final c = controller.country;
        final choosable = countries.length > 1 || !countries.contains(c);
        final labelText = '+${c.dialCode}';
        final bodyStyle = TextStyles.body.copyWith(color: p.label);
        // Drapeau en image (les emojis drapeaux ne s'affichent pas partout) puis l'indicatif
        final label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CountryFlag(iso: c.iso, height: 15),
            const SizedBox(width: 6),
            Text(
              labelText,
              style: bodyStyle,
              maxLines: 1,
              softWrap: false,
              strutStyle: StrutStyle.fromTextStyle(
                TextStyles.body,
                forceStrutHeight: true,
              ),
            ),
          ],
        );
        final hint = placeholder ?? c.phoneExample;
        return LayoutBuilder(
          builder: (context, constraints) {
            // Place laissée au bouton de droite : le numéro complet reste lisible
            double? trailingMax;
            if (trailing != null && constraints.hasBoundedWidth) {
              final scaler = MediaQuery.textScalerOf(context);
              double w(String t) {
                final tp = TextPainter(
                  text: TextSpan(text: t, style: bodyStyle),
                  textScaler: scaler,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                )..layout();
                final width = tp.width;
                tp.dispose();
                return width;
              }

              final chip = w(labelText) + 27 + 8 + (choosable ? 16 : 0);
              final digits = '0' * (c.phoneLength + c.trunkPrefix.length);
              final field =
                  [w(hint), w(digits)].reduce((a, b) => a > b ? a : b) + 4;
              trailingMax = (constraints.maxWidth - 20 - chip - field).clamp(
                44.0,
                double.infinity,
              );
            }
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: trailing == null ? 16 : 4,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (choosable)
                    Semantics(
                      button: true,
                      label: 'Indicatif du pays : ${c.name}',
                      child: GestureDetector(
                        key: const ValueKey('phone-country'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _pick(context),
                        child: Padding(
                          padding: const EdgeInsets.only(
                            top: 14,
                            bottom: 8,
                            right: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              label,
                              const SizedBox(width: 3),
                              Icon(
                                CupertinoIcons.chevron_down,
                                size: 13,
                                color: p.tertiaryLabel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Padding(
                      key: const ValueKey('phone-country'),
                      padding: const EdgeInsets.only(top: 14, right: 8),
                      child: label,
                    ),
                  Expanded(
                    child: TextFormField(
                      controller: controller,
                      autofocus: autofocus,
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d +]')),
                      ],
                      validator: validate
                          ? (_) => controller.validate(required: required)
                          : null,
                      onChanged: _changed,
                      style: TextStyles.body.copyWith(color: p.label),
                      decoration: InputDecoration(
                        hintText: hint,
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 11,
                        ),
                        errorStyle: TextStyles.footnote.copyWith(color: p.red),
                        errorMaxLines: 3,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: trailingMax ?? double.infinity,
                      ),
                      child: trailing,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Bouton « Répertoire » à droite d'un [PhoneField] ; icône seule si la place manque
class ContactButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  const ContactButton({
    super.key,
    required this.onPressed,
    this.label = 'Répertoire',
  });

  static const _padding = EdgeInsets.only(right: 10, left: 6);
  static const _iconSize = 22.0;

  @override
  Widget build(BuildContext context) {
    final style = TextStyles.subheadline.copyWith(
      color: accent,
      fontWeight: FontWeight.w600,
    );
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: label, style: style),
          textScaler: scaler,
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final full = _padding.horizontal + _iconSize + 4 + tp.width + 1;
        tp.dispose();
        final showLabel = full <= constraints.maxWidth;
        return Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: CupertinoButton(
            padding: _padding,
            minimumSize: const Size(44, 44),
            onPressed: onPressed,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  PhosphorIcons.addressBook(PhosphorIconsStyle.fill),
                  color: accent,
                  size: _iconSize,
                ),
                if (showLabel) ...[
                  const SizedBox(width: 4),
                  Text(label, style: style, maxLines: 1, softWrap: false),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Feuille de choix du pays (pays actifs : drapeau, nom, indicatif)
Future<Country?> showCountryPicker(BuildContext context, {Country? selected}) {
  return showModalBottomSheet<Country>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Palette.of(context).background,
    shape: const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CountrySheet(selected: selected),
  );
}

class _CountrySheet extends StatefulWidget {
  final Country? selected;
  const _CountrySheet({this.selected});
  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _q = '';

  static String _fold(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[àâä]'), 'a')
      .replaceAll(RegExp('[îï]'), 'i')
      .replaceAll(RegExp('[ôö]'), 'o')
      .replaceAll(RegExp('[ùûü]'), 'u')
      .replaceAll('ç', 'c');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final all = Countries.instance.list;
    final q = _fold(_q.trim().replaceAll('+', ''));
    final shown = q.isEmpty
        ? all
        : all
              .where(
                (c) =>
                    _fold(c.name).contains(q) ||
                    c.iso.toLowerCase() == q ||
                    c.dialCode.startsWith(q),
              )
              .toList();
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Grabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Text(
                'Indicatif du pays',
                style: TextStyles.headline.copyWith(color: p.label),
              ),
            ),
            if (all.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: CupertinoSearchTextField(
                  placeholder: 'Rechercher un pays',
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            Flexible(
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Aucun pays',
                        style: TextStyles.body.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: p.card,
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: shown.length,
                            separatorBuilder: (_, _) => Padding(
                              padding: const EdgeInsets.only(left: 52),
                              child: Divider(
                                height: 0.5,
                                thickness: 0.5,
                                color: p.separator,
                              ),
                            ),
                            itemBuilder: (_, i) {
                              final c = shown[i];
                              final selected = c == widget.selected;
                              return InkWell(
                                onTap: () {
                                  hapticTap();
                                  Navigator.pop(context, c);
                                },
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 46,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 30,
                                          child: CountryFlag(
                                            iso: c.iso,
                                            height: 20,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            c.name,
                                            style: TextStyles.body.copyWith(
                                              color: p.label,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '+${c.dialCode}',
                                          style: TextStyles.body.copyWith(
                                            color: p.secondaryLabel,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 28,
                                          child: selected
                                              ? const Icon(
                                                  CupertinoIcons.checkmark_alt,
                                                  size: 18,
                                                  color: accent,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
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
