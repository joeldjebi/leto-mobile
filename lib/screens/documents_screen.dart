import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../main.dart';
import '../realtime.dart';
import 'widgets.dart';

/// Dev / tests : photo déjà envoyée utilisée à la place de l'appareil photo
const _devPhoto = String.fromEnvironment('DEV_PHOTO');

/// Documents renouvelables : clé, libellé, caméra avant ?
const _docs = [
  ('licenseUrl', 'Permis de conduire', false),
  ('insuranceUrl', 'Assurance', false),
  ('registrationUrl', 'Carte grise', false),
  ('idFrontUrl', 'Pièce d’identité (recto)', false),
  ('idBackUrl', 'Pièce d’identité (verso)', false),
  ('docsSelfieUrl', 'Vous avec vos documents', true),
];

/// Documents avec une date de fin de validité
const _expiring = {'licenseUrl': 'license', 'insuranceUrl': 'insurance'};

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 2027-01-31 → 31/01/2027
String frDate(String iso) => iso.split('-').reversed.join('/');

/// Choix d'une date de fin de validité (aujourd'hui au plus tôt) ; null = annulé
Future<String?> pickExpiryDate(
  BuildContext context,
  String title,
  String? current,
) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  var picked =
      DateTime.tryParse(current ?? '') ??
      DateTime(now.year + 1, now.month, now.day);
  if (picked.isBefore(today)) picked = today;
  final ok = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (ctx) => Container(
      height: 320,
      color: Palette.of(ctx).card,
      child: Column(
        children: [
          Row(
            children: [
              CupertinoButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuler'),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyles.subheadline.copyWith(
                    color: Palette.of(ctx).label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CupertinoButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK'),
              ),
            ],
          ),
          Expanded(
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.date,
              initialDateTime: picked,
              minimumDate: today,
              maximumDate: DateTime(now.year + 15),
              onDateTimeChanged: (d) => picked = d,
            ),
          ),
        ],
      ),
    ),
  );
  return ok == true ? _iso(picked) : null;
}

/// Livreur indépendant : validité du permis et de l'assurance, documents à renouveler,
/// demandes de son entreprise. Chaque nouveau document est vérifié par VITE.
class DocumentsScreen extends StatefulWidget {
  /// Dossier déjà chargé (tests) ; sinon chargé à l'ouverture
  final Map<String, dynamic>? initial;
  const DocumentsScreen({super.key, this.initial});
  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final api = Api.instance;
  late Map<String, dynamic>? _d = widget.initial;
  String? _busy;
  void Function()? _unlisten;

  @override
  void initState() {
    super.initState();
    if (_d == null) _load();
    // Document validé ou refusé par VITE, demande de l'entreprise : en direct
    if (api.token == null) return;
    final s = Realtime.instance.socket;
    s.on('independent:docs', _onChanged);
    _unlisten = () => s.off('independent:docs', _onChanged);
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }

  void _onChanged(dynamic _) => _load();

  Future<void> _load() async {
    try {
      final d = await api.myDossier();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  List<Map> get _renewals => ((_d?['renewals'] as List?) ?? []).cast<Map>();
  List<Map> get _requests =>
      ((_d?['updateRequests'] as List?) ?? []).cast<Map>();
  Map? _state(String key) => (_d?['docs'] as Map?)?[key] as Map?;

  Future<String?> _photo(String field, bool front) async {
    if (_devPhoto.isNotEmpty) return _devPhoto;
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera, // appareil photo uniquement
      preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
      maxWidth: 1600,
      imageQuality: 75,
    );
    if (file == null) return null;
    return api.uploadIdentity(File(file.path));
  }

  Future<void> _renew(String field, String label, bool front) async {
    if (_busy != null) return;
    final exp = _expiring[field];
    final current = exp == null ? null : _state(exp)?['expiresOn'] as String?;
    var withPhoto = true;
    if (exp != null && current == null) {
      // Dossier validé avant les dates : la date seule suffit si la photo est à jour
      final choice = await showActions<bool>(
        context,
        title: label,
        message: 'VITE vérifie la date sur la photo de votre document.',
        actions: [
          ('Prendre une nouvelle photo', true, false),
          ('Indiquer seulement la date', false, false),
        ],
      );
      if (choice == null) return;
      withPhoto = choice;
    } else {
      final ok = await confirm(
        context,
        label,
        message: exp == null
            ? 'Prenez le document en photo, bien à plat et lisible. VITE le vérifie avant qu’il remplace l’ancien.'
            : 'Prenez le nouveau document en photo puis indiquez sa date de fin de validité. VITE le vérifie avant qu’il remplace l’ancien.',
        ok: 'Prendre la photo',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => _busy = field);
    try {
      String? url;
      if (withPhoto) {
        url = await _photo(field, front);
        if (url == null) return;
      }
      String? date;
      if (exp != null) {
        if (!mounted) return;
        date = await pickExpiryDate(context, 'Valable jusqu’au', current);
        if (date == null) return;
      }
      final d = await api.submitRenewal(field, url: url, expiresOn: date);
      if (!mounted) return;
      hapticSuccess();
      setState(() => _d = d);
      showInfo(context, 'Envoyé : VITE vérifie votre document');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = _d;
    return LargeTitlePage(
      title: 'Mes documents',
      onRefresh: _load,
      children: [
        if (d == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          )
        else ...[
          _banner(p),
          if (_requests.isNotEmpty)
            InsetGroup(
              header: 'Demandé par votre entreprise',
              children: [
                for (final r in _requests)
                  GroupRow(
                    leading: const IconBadge(
                      PhosphorIconsFill.buildings,
                      color: accent,
                    ),
                    title: _cap(r['label'] ?? ''),
                    subtitle: [
                      if ((r['note'] ?? '').toString().isNotEmpty)
                        '« ${r['note']} »',
                      if (_renewals.any((x) => x['field'] == r['field']))
                        'Envoyé, en vérification par VITE',
                    ].join(' · '),
                    chevron: true,
                    onTap: () {
                      final doc = _docs.firstWhere((x) => x.$1 == r['field']);
                      _renew(doc.$1, doc.$2, doc.$3);
                    },
                  ),
              ],
            ),
          InsetGroup(
            header: 'Validité',
            footer:
                'Vous et votre entreprise êtes prévenus 30 jours avant la fin de validité. Une fois la date passée, vous ne recevez plus de courses jusqu’à ce que VITE valide le nouveau document.',
            children: [
              _validity(p, 'licenseUrl', 'Permis de conduire', 'license'),
              _validity(p, 'insuranceUrl', 'Assurance', 'insurance'),
            ],
          ),
          InsetGroup(
            header: 'Documents',
            footer:
                'Touchez un document pour envoyer une nouvelle photo. L’ancien reste valable jusqu’à la validation du nouveau.',
            children: [
              for (final (field, label, front) in _docs)
                GroupRow(
                  leading: _thumb(p, field),
                  title: label,
                  subtitle: _status(field),
                  trailing: _busy == field
                      ? const CupertinoActivityIndicator()
                      : null,
                  chevron: _busy != field,
                  onTap: () => _renew(field, label, front),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  String? _status(String field) {
    if (_renewals.any((x) => x['field'] == field)) {
      return 'Nouveau document en vérification par VITE';
    }
    if (_requests.any((x) => x['field'] == field)) {
      return 'Mise à jour demandée par votre entreprise';
    }
    return null;
  }

  /// Bandeau : document expiré (courses bloquées) ou bientôt expiré
  Widget _banner(Palette p) {
    final states = [_state('license')?['state'], _state('insurance')?['state']];
    final expired = states.contains('EXPIRED');
    final soon = states.contains('SOON');
    if (!expired && !soon) return const SizedBox.shrink();
    final color = expired ? p.red : p.yellow;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            expired ? PhosphorIconsFill.warningCircle : PhosphorIconsFill.clock,
            color: color,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  expired ? 'Document expiré' : 'Document bientôt expiré',
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                const SizedBox(height: 2),
                Text(
                  expired
                      ? 'Vous ne recevez plus de courses. Envoyez le nouveau document ci-dessous : vous reprenez dès que VITE l’a validé.'
                      : 'Envoyez le nouveau document avant la date pour continuer à recevoir des courses sans interruption.',
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _validity(Palette p, String field, String label, String key) {
    final s = _state(key);
    final date = s?['expiresOn'] as String?;
    final pending = _renewals.where((x) => x['field'] == field).firstOrNull;
    final (String chip, Color color) = switch (s?['state']) {
      'OK' => ('Valide', p.green),
      'SOON' => ('Expire bientôt', p.yellow),
      'EXPIRED' => ('Expiré', p.red),
      _ => ('Date à indiquer', p.secondaryLabel),
    };
    final doc = _docs.firstWhere((x) => x.$1 == field);
    return GroupRow(
      leading: Icon(
        PhosphorIconsBold.calendarCheck,
        color: p.secondaryLabel,
        size: 20,
      ),
      title: label,
      subtitle: [
        date == null
            ? 'Date de fin de validité non renseignée'
            : 'Valable jusqu’au ${frDate(date)}',
        if (pending != null && pending['expiresOn'] != null)
          'Nouveau : ${frDate(pending['expiresOn'])}, en vérification',
      ].join('\n'),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: ShapeDecoration(
          color: color.withValues(alpha: 0.14),
          shape: const StadiumBorder(),
        ),
        child: Text(
          chip,
          style: TextStyles.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      onTap: () => _renew(doc.$1, doc.$2, doc.$3),
    );
  }

  Widget _thumb(Palette p, String field) {
    final link = (_d?['links'] as Map?)?[field] as String?;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: link == null
            ? Container(
                color: p.fill,
                child: Icon(PhosphorIconsFill.camera, color: accent, size: 18),
              )
            : Image.network(
                photoUrl(link),
                fit: BoxFit.cover,
                // Miniature 40 px : inutile de décoder la photo en pleine résolution
                cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => Container(color: p.fill),
              ),
      ),
    );
  }
}
