import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import 'widgets.dart';

/// Entreprise choisie par le client ({id, name}) ; null = toutes les entreprises
typedef ChosenCompany = ({String id, String name});

/// Choix « Livreurs indépendants » (id spécial, jamais une entreprise)
const ChosenCompany independentChoice = (
  id: kIndependentId,
  name: 'Livreurs indépendants',
);

extension ChosenCompanyX on ChosenCompany? {
  bool get isIndependent => this?.id == kIndependentId;
}

const _favKey = 'favorite_company';

/// Entreprise favorite mémorisée (présélectionnée à chaque commande)
Future<ChosenCompany?> loadFavoriteCompany() async {
  final p = await SharedPreferences.getInstance();
  final v = p.getStringList(_favKey);
  return v == null || v.length != 2 ? null : (id: v[0], name: v[1]);
}

Future<void> _saveFavorite(ChosenCompany? c) async {
  final p = await SharedPreferences.getInstance();
  c == null
      ? await p.remove(_favKey)
      : await p.setStringList(_favKey, [c.id, c.name]);
}

/// Annuaire des entreprises de livraison : grille, livreurs en ligne, taux de réussite.
/// Renvoie ('all', null) pour toutes les entreprises, ('one', entreprise) sinon, null si fermé.
Future<(String, ChosenCompany?)?> pickCompany(
  BuildContext context,
  ChosenCompany? current,
) => showModalBottomSheet<(String, ChosenCompany?)>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Palette.of(context).background,
  shape: const RoundedSuperellipseBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (_) => _CompanyPicker(current: current),
);

class _CompanyPicker extends StatefulWidget {
  final ChosenCompany? current;
  const _CompanyPicker({this.current});
  @override
  State<_CompanyPicker> createState() => _CompanyPickerState();
}

class _CompanyPickerState extends State<_CompanyPicker> {
  List<Map<String, dynamic>>? _list;
  Map<String, dynamic>? _independents;
  String? _favorite;
  String? _expanded;

  @override
  void initState() {
    super.initState();
    loadFavoriteCompany().then(
      (f) => mounted ? setState(() => _favorite = f?.id) : null,
    );
    Api.instance
        .independentsInfo()
        .then((i) => mounted ? setState(() => _independents = i) : null)
        .catchError((_) => null);
    Api.instance.companiesDirectory().then(
      (l) => mounted
          ? setState(() => _list = l.cast<Map<String, dynamic>>())
          : null,
      onError: (e) => mounted ? showError(context, e) : null,
    );
  }

  Future<void> _toggleFavorite(Map<String, dynamic> c) async {
    hapticTap();
    final on = _favorite != c['id'];
    await _saveFavorite(
      on ? (id: c['id'] as String, name: c['name'] as String) : null,
    );
    setState(() => _favorite = on ? c['id'] : null);
    if (mounted) {
      showInfo(
        context,
        on
            ? '${c['name']} : entreprise favorite, choisie par défaut'
            : 'Favorite retirée',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          const Center(child: Grabber()),
          const SizedBox(height: 16),
          Text(
            'QUI LIVRE ?',
            style: TextStyles.displaySmall.copyWith(color: p.label),
          ),
          Text(
            'Laissez LETO trouver le livreur le plus proche, ou choisissez votre entreprise de livraison.',
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
          const SizedBox(height: 16),
          _tile(
            p,
            selected: widget.current == null,
            icon: CupertinoIcons.bolt_fill,
            title: 'Toutes les entreprises',
            subtitle: 'Le livreur disponible le plus proche · grille LETO',
            onTap: () => Navigator.pop(context, ('all', null)),
          ),
          if (_independents?['enabled'] == true) ...[
            const SizedBox(height: 10),
            _independentTile(p),
          ],
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'ENTREPRISES DE LIVRAISON',
              style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
            ),
          ),
          if (_list == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CupertinoActivityIndicator(),
            )
          else if (_list!.isEmpty)
            Text(
              'Aucune entreprise disponible pour le moment.',
              style: TextStyles.body.copyWith(color: p.secondaryLabel),
            )
          else
            for (final c in [
              ..._list!.where((c) => c['id'] == _favorite),
              ..._list!.where((c) => c['id'] != _favorite),
            ])
              _company(c, p),
        ],
      ),
    );
  }

  /// Livreurs indépendants : toujours signalés comme tels, avec confirmation
  Widget _independentTile(Palette p) {
    final selected = widget.current.isIndependent;
    final online = _independents?['online'] ?? 0;
    return Pressable(
      onTap: () async {
        final ok = await confirm(
          context,
          'Livreurs indépendants',
          message: IndependentNotice.text,
          ok: 'Choisir un indépendant',
        );
        if (ok && mounted) Navigator.pop(context, ('one', independentChoice));
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: independentColor.withValues(alpha: 0.12),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: selected ? accent : independentColor,
              width: 1.6,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                color: independentColor,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Icon(
                Icons.two_wheeler,
                color: Color(0xFF1F1300),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const IndependentBadge(),
                  const SizedBox(height: 4),
                  Text(
                    'Livreurs indépendants',
                    style: TextStyles.headline.copyWith(color: p.label),
                  ),
                  Text(
                    'Sans entreprise · vérifiés par LETO · grille LETO · pas de paiement à la livraison${online > 0 ? ' · $online en ligne' : ''}',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(CupertinoIcons.checkmark_circle_fill, color: accent),
          ],
        ),
      ),
    );
  }

  Widget _tile(
    Palette p, {
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Pressable(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? accent : Colors.transparent,
            width: 1.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: ShapeDecoration(
              gradient: letoGradient,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                Text(
                  subtitle,
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ],
            ),
          ),
          if (selected)
            const Icon(CupertinoIcons.checkmark_circle_fill, color: accent),
        ],
      ),
    ),
  );

  Widget _company(Map<String, dynamic> c, Palette p) {
    final selected = widget.current?.id == c['id'];
    final vehicles = (c['vehicles'] as List).cast<Map<String, dynamic>>();
    final moto =
        vehicles.where((v) => v['vehicle'] == 'MOTO').firstOrNull ??
        vehicles.firstOrNull;
    final online = (c['online'] ?? 0) as int;
    final rate = c['successRate'];
    final open = _expanded == c['id'];
    final fav = _favorite == c['id'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: selected ? accent : Colors.transparent,
              width: 1.6,
            ),
          ),
        ),
        child: Column(
          children: [
            Pressable(
              pressedScale: 0.99,
              onTap: () => Navigator.pop(context, (
                'one',
                (id: c['id'] as String, name: c['name'] as String),
              )),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 6, 10),
                child: Row(
                  children: [
                    Avatar(c['name'], radius: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c['name'],
                            style: TextStyles.headline.copyWith(color: p.label),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              online > 0
                                  ? '$online livreur(s) en ligne'
                                  : 'Aucun livreur en ligne',
                              if (rate != null) '$rate % de réussite',
                            ].join(' · '),
                            style: TextStyles.footnote.copyWith(
                              color: online > 0 ? p.green : p.secondaryLabel,
                            ),
                          ),
                          if (moto != null)
                            Text(
                              '${vehicleLabels[moto['vehicle']] ?? moto['label']} dès ${fcfa(moto['min'])} · ~${fcfa(moto['sample5km'])} pour 5 km',
                              style: TextStyles.footnote.copyWith(
                                color: p.secondaryLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: fav
                          ? 'Retirer des favoris'
                          : 'Entreprise favorite',
                      onPressed: () => _toggleFavorite(c),
                      icon: Icon(
                        fav ? CupertinoIcons.star_fill : CupertinoIcons.star,
                        color: fav ? p.yellow : p.tertiaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.only(bottom: 10),
              minimumSize: Size.zero,
              onPressed: () =>
                  setState(() => _expanded = open ? null : c['id']),
              child: Text(
                open
                    ? 'Masquer la grille tarifaire'
                    : 'Voir la grille tarifaire',
                style: TextStyles.subheadline.copyWith(color: accent),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Column(
                  children: [
                    for (final v in vehicles)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              vehicleIcons[v['vehicle']],
                              size: 20,
                              color: p.secondaryLabel,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                vehicleLabels[v['vehicle']] ?? v['label'],
                                style: TextStyles.subheadline.copyWith(
                                  color: p.label,
                                ),
                              ),
                            ),
                            Text(
                              '${fcfa(v['base'])} + ${fcfa(v['perKm'])}/km · min ${fcfa(v['min'])}',
                              style: TextStyles.footnote.copyWith(
                                color: p.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if ((c['extraStopFee'] ?? 0) > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Arrêt supplémentaire : ${fcfa(c['extraStopFee'])}',
                          style: TextStyles.footnote.copyWith(
                            color: p.secondaryLabel,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
