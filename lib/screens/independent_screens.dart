import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import '../realtime.dart';
import 'documents_screen.dart';
import 'driver_home.dart';
import 'widgets.dart';

/// Dev / tests : photo déjà envoyée utilisée à la place de l'appareil photo
const _devPhoto = String.fromEnvironment('DEV_PHOTO');

const _communes = [
  'Abobo',
  'Adjamé',
  'Anyama',
  'Attécoubé',
  'Bingerville',
  'Cocody',
  'Koumassi',
  'Marcory',
  'Plateau',
  'Port-Bouët',
  'Songon',
  'Treichville',
  'Yopougon',
  'Autre',
];

const _idTypes = {
  'CNI': 'Carte nationale d’identité',
  'PASSPORT': 'Passeport',
  'CONSULAR': 'Carte consulaire',
  'RESIDENCE': 'Carte de séjour',
};

/// Photos du dossier : clé, libellé, aide, caméra avant ?
const _photos = [
  (
    'selfieUrl',
    'Selfie',
    'Votre visage, bien éclairé. Ce sera votre photo de profil.',
    true,
  ),
  (
    'docsSelfieUrl',
    'Vous avec vos documents',
    'Tenez votre pièce, votre permis et votre carte grise à côté de votre visage.',
    true,
  ),
  ('idFrontUrl', 'Pièce d’identité (recto)', null, false),
  ('idBackUrl', 'Pièce d’identité (verso)', null, false),
  ('licenseUrl', 'Permis de conduire', null, false),
  ('registrationUrl', 'Carte grise', null, false),
  ('insuranceUrl', 'Assurance', null, false),
];

// ======================================================================
// Inscription
// ======================================================================

/// Création du compte d'un livreur indépendant (avant le dossier)
class IndependentSignupScreen extends StatefulWidget {
  const IndependentSignupScreen({super.key});
  @override
  State<IndependentSignupScreen> createState() =>
      _IndependentSignupScreenState();
}

class _IndependentSignupScreenState extends State<IndependentSignupScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = PhoneController();
  final _password = TextEditingController();
  bool _loading = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await Api.instance.registerIndependent(
        _name.text.trim(),
        _phone.e164!,
        _password.text,
      );
      hapticSuccess();
      if (mounted) goHome(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget need(IconData icon, String text) => GroupRow(
      leading: Icon(icon, color: accent, size: 20),
      title: text,
    );
    return LargeTitlePage(
      title: 'Livreur indépendant',
      bottomBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const CupertinoActivityIndicator(color: Colors.white)
              : const Text('Créer mon compte'),
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text(
            'Livrez avec votre propre engin, sans entreprise. VITE vérifie votre identité avant votre première course.',
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
        ),
        InsetGroup(
          header: 'Ce qu’il vous faut',
          children: [
            need(
              PhosphorIconsFill.identificationBadge,
              'Une pièce d’identité valide',
            ),
            need(
              PhosphorIconsFill.fileText,
              'Permis, carte grise et assurance de votre engin',
            ),
            need(
              PhosphorIconsFill.camera,
              'Un selfie et une photo avec vos documents en main',
            ),
            need(
              PhosphorIconsFill.creditCard,
              'Un solde prépayé : la commission VITE est prélevée à chaque course',
            ),
          ],
        ),
        Form(
          key: _form,
          child: InsetGroup(
            header: 'Votre compte',
            footer:
                'Les courses avec paiement à la livraison sont réservées aux entreprises.',
            children: [
              GroupField(
                controller: _name,
                placeholder: 'Nom et prénoms (comme sur la pièce)',
                icon: PhosphorIconsBold.user,
                validator: (v) => (v ?? '').trim().length < 3
                    ? 'Nom complet obligatoire'
                    : null,
              ),
              PhoneField(controller: _phone, validate: true),
              GroupField(
                controller: _password,
                placeholder: 'Mot de passe (6 caractères minimum)',
                icon: PhosphorIconsBold.lock,
                obscure: true,
                validator: (v) =>
                    (v ?? '').length < 6 ? '6 caractères minimum' : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ======================================================================
// Aiguillage : dossier tant qu'il n'est pas validé, sinon l'accueil livreur
// ======================================================================

class IndependentGate extends StatefulWidget {
  const IndependentGate({super.key});
  @override
  State<IndependentGate> createState() => _IndependentGateState();
}

class _IndependentGateState extends State<IndependentGate> {
  Map<String, dynamic>? _dossier;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.myDossier();
      if (mounted) setState(() => _dossier = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (_dossier?['status'] == 'APPROVED') return const DriverHome();
    if (_dossier != null) return DossierScreen(initial: _dossier!);
    return Scaffold(
      backgroundColor: p.background,
      body: Center(
        child: _error == null
            ? const CupertinoActivityIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      friendlyError(_error),
                      textAlign: TextAlign.center,
                      style: TextStyles.body.copyWith(color: p.label),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _load();
                      },
                      child: const Text('Réessayer'),
                    ),
                    CupertinoButton(
                      onPressed: () async {
                        await Api.instance.logout();
                        if (context.mounted) goHome(context);
                      },
                      child: const Text('Se déconnecter'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

// ======================================================================
// Dossier
// ======================================================================

/// Dossier du livreur indépendant : identité, engin, photos (appareil photo uniquement)
class DossierScreen extends StatefulWidget {
  final Map<String, dynamic> initial;
  const DossierScreen({super.key, required this.initial});
  @override
  State<DossierScreen> createState() => _DossierScreenState();
}

class _DossierScreenState extends State<DossierScreen> {
  final api = Api.instance;
  late Map<String, dynamic> _d = widget.initial;
  final _form = GlobalKey<FormState>();
  late final _address = TextEditingController(text: _d['address']);
  late final _idNumber = TextEditingController(text: _d['idNumber']);
  late final _emergencyName = TextEditingController(text: _d['emergencyName']);
  late final _emergencyPhone = PhoneController(_d['emergencyPhone']);
  late final _brand = TextEditingController(text: _d['vehicleBrand']);
  late final _plate = TextEditingController(text: _d['vehiclePlate']);
  late final _license = TextEditingController(text: _d['licenseNumber']);
  late String? _birthDate = _d['birthDate'];
  late String? _licenseExp = _d['licenseExpiresOn'];
  late String? _insuranceExp = _d['insuranceExpiresOn'];
  late String? _commune = _d['commune'];
  late String _idType = _d['idType'] ?? 'CNI';
  late String _vehicle = _d['vehicleType'] ?? _defaultVehicle();

  /// Moto par défaut, sinon le premier engin proposé
  static String _defaultVehicle() {
    final codes = Vehicles.instance.enabled.map((v) => v.code);
    return codes.contains('MOTO') || codes.isEmpty ? 'MOTO' : codes.first;
  }

  /// Engins proposés (catalogue actif), plus celui déjà choisi s'il n'est plus proposé
  List<String> get _vehicleChoices {
    final codes = [for (final v in Vehicles.instance.enabled) v.code];
    if (!codes.contains(_vehicle)) codes.add(_vehicle);
    return codes;
  }

  late bool _consent = _d['consentAt'] != null;
  final Map<String, File> _local = {};
  final Set<String> _uploading = {};
  bool _saving = false;
  void Function()? _unlisten;

  String get _status => _d['status'] ?? 'DRAFT';
  bool get _editable => _status == 'DRAFT' || _status == 'REJECTED';
  bool get _standalone => Navigator.canPop(context);

  @override
  void initState() {
    super.initState();
    // Décision de VITE en direct
    if (api.token == null) return;
    final s = Realtime.instance.socket;
    void handler(dynamic _) => _reload();
    s.on('independent:status', handler);
    _unlisten = () => s.off('independent:status', handler);
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final d = await api.myDossier();
      if (!mounted) return;
      if (d['status'] == 'APPROVED' && !_standalone) {
        hapticSuccess();
        showInfo(context, 'Dossier validé : bienvenue chez VITE !');
        goHome(context);
        return;
      }
      setState(() => _d = d);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Map<String, dynamic> _fields() => {
    'birthDate': ?_birthDate,
    'commune': ?_commune,
    'address': _address.text.trim(),
    'idType': _idType,
    'idNumber': _idNumber.text.trim(),
    'emergencyName': _emergencyName.text.trim(),
    if (_emergencyPhone.e164 != null) 'emergencyPhone': _emergencyPhone.e164,
    'vehicleType': _vehicle,
    'vehicleBrand': _brand.text.trim(),
    'vehiclePlate': _plate.text.trim(),
    'licenseNumber': _license.text.trim(),
    'licenseExpiresOn': ?_licenseExp,
    'insuranceExpiresOn': ?_insuranceExp,
    if (_consent) 'consent': true,
  };

  Future<bool> _save({bool quiet = false}) async {
    if (!_form.currentState!.validate()) return false;
    setState(() => _saving = true);
    try {
      final d = await api.saveDossier(_fields());
      if (!mounted) return false;
      setState(() => _d = d);
      if (!quiet) showInfo(context, 'Dossier enregistré');
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _send() async {
    if (!_consent) {
      showError(
        context,
        'Acceptez le traitement de vos données pour envoyer le dossier',
      );
      return;
    }
    if (!await _save(quiet: true)) return;
    setState(() => _saving = true);
    try {
      final d = await api.submitDossier();
      if (!mounted) return;
      hapticSuccess();
      setState(() => _d = d);
      showInfo(context, 'Dossier envoyé : VITE le vérifie au plus vite');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _capture(String key, bool front) async {
    final isSelfie = key == 'selfieUrl';
    String url;
    if (_devPhoto.isNotEmpty) {
      url = _devPhoto;
    } else {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera, // appareil photo uniquement
        preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
        maxWidth: 1600,
        imageQuality: 75,
      );
      if (file == null || !mounted) return;
      setState(() {
        _local[key] = File(file.path);
        _uploading.add(key);
      });
      try {
        url = isSelfie
            ? await api.upload(File(file.path))
            : await api.uploadIdentity(File(file.path));
      } catch (e) {
        if (mounted) {
          setState(() {
            _local.remove(key);
            _uploading.remove(key);
          });
          showError(context, e);
        }
        return;
      }
    }
    try {
      final d = await api.saveDossier({key: url});
      if (!mounted) return;
      setState(() {
        _d = d;
        _uploading.remove(key);
      });
      if (isSelfie) api.user?['avatarUrl'] = url;
    } catch (e) {
      if (mounted) {
        setState(() => _uploading.remove(key));
        showError(context, e);
      }
    }
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    var picked = _birthDate != null
        ? DateTime.parse(_birthDate!)
        : DateTime(now.year - 25, 1, 1);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 300,
        color: Palette.of(ctx).card,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: picked,
                minimumDate: DateTime(now.year - 80),
                maximumDate: DateTime(now.year - 18, now.month, now.day),
                onDateTimeChanged: (d) => picked = d,
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(
      () => _birthDate =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
    );
  }

  Future<void> _pickExpiry(bool license) async {
    final d = await pickExpiryDate(
      context,
      license ? 'Fin de validité du permis' : 'Fin de validité de l’assurance',
      license ? _licenseExp : _insuranceExp,
    );
    if (d == null || !mounted) return;
    setState(() => license ? _licenseExp = d : _insuranceExp = d);
  }

  Future<void> _choose<T>(
    String title,
    Map<T, String> options,
    void Function(T) set,
  ) async {
    final v = await showActions<T>(
      context,
      title: title,
      actions: [for (final e in options.entries) (e.value, e.key, false)],
    );
    if (v != null && mounted) setState(() => set(v));
  }

  String _dateLabel(String iso) {
    final d = DateTime.parse(iso);
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final required = (_d['required'] as List? ?? []).cast<Map>();
    final done = required.where((r) => r['ok'] == true).length;
    final e = _editable;
    return LargeTitlePage(
      title: 'Mon dossier',
      trailing: _standalone
          ? null
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () async {
                await api.logout();
                if (context.mounted) goHome(context);
              },
              child: Text(
                'Déconnexion',
                style: TextStyles.subheadline.copyWith(color: accent),
              ),
            ),
      onRefresh: _reload,
      bottomBar: e
          ? GlassBottomBar(
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => _save(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('Enregistrer'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _saving || _uploading.isNotEmpty
                          ? null
                          : _send,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: Text(
                        _saving
                            ? '…'
                            : _status == 'REJECTED'
                            ? 'Renvoyer le dossier'
                            : 'Envoyer le dossier',
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
      children: [
        _statusCard(p, done, required.length),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _section(p, 'Photos de vous', [_photos[0], _photos[1]]),
              InsetGroup(
                header: 'Identité',
                children: [
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.calendarBlank,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: 'Date de naissance',
                    value: _birthDate == null
                        ? 'Choisir'
                        : _dateLabel(_birthDate!),
                    chevron: e,
                    onTap: e ? _pickBirthDate : null,
                  ),
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.mapPinArea,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: 'Commune',
                    value: _commune ?? 'Choisir',
                    chevron: e,
                    onTap: e
                        ? () => _choose<String>('Votre commune', {
                            for (final c in _communes) c: c,
                          }, (v) => _commune = v)
                        : null,
                  ),
                  _field(
                    _address,
                    'Quartier, repère',
                    PhosphorIconsFill.house,
                    required: true,
                  ),
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.identificationBadge,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: 'Pièce',
                    value: _idTypes[_idType],
                    chevron: e,
                    onTap: e
                        ? () => _choose<String>(
                            'Type de pièce',
                            _idTypes,
                            (v) => _idType = v,
                          )
                        : null,
                  ),
                  _field(
                    _idNumber,
                    'Numéro de la pièce',
                    PhosphorIconsBold.hash,
                    required: true,
                  ),
                ],
              ),
              _section(p, 'Pièce d’identité', [_photos[2], _photos[3]]),
              InsetGroup(
                header: 'Engin',
                children: [
                  ListenableBuilder(
                    listenable: Vehicles.instance,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.all(12),
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _vehicle,
                        onValueChanged: (v) {
                          if (e && v != null) setState(() => _vehicle = v);
                        },
                        children: {
                          for (final v in _vehicleChoices)
                            v: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(vehicleName(v), maxLines: 1),
                              ),
                            ),
                        },
                      ),
                    ),
                  ),
                  _field(
                    _brand,
                    'Marque et modèle (ex. Haojue 125)',
                    PhosphorIconsBold.car,
                    required: true,
                  ),
                  _field(
                    _plate,
                    'Immatriculation',
                    PhosphorIconsBold.textAa,
                    required: true,
                  ),
                  _field(
                    _license,
                    'Numéro du permis (facultatif)',
                    PhosphorIconsBold.fileText,
                  ),
                ],
              ),
              _section(p, 'Documents de l’engin', [
                _photos[4],
                _photos[5],
                _photos[6],
              ]),
              InsetGroup(
                header: 'Validité des documents',
                footer:
                    'Lisez la date sur le document. Vous serez prévenu 30 jours avant ; une fois la date passée, vous ne recevez plus de courses tant que le nouveau document n’est pas validé.',
                children: [
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.calendarCheck,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: 'Permis valable jusqu’au',
                    value: _licenseExp == null
                        ? 'Choisir'
                        : _dateLabel(_licenseExp!),
                    chevron: e,
                    onTap: e ? () => _pickExpiry(true) : null,
                  ),
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.calendarCheck,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: 'Assurance valable jusqu’au',
                    value: _insuranceExp == null
                        ? 'Choisir'
                        : _dateLabel(_insuranceExp!),
                    chevron: e,
                    onTap: e ? () => _pickExpiry(false) : null,
                  ),
                ],
              ),
              InsetGroup(
                header: 'Contact d’urgence (facultatif)',
                children: [
                  _field(_emergencyName, 'Nom', PhosphorIconsFill.users),
                  PhoneField(
                    controller: _emergencyPhone,
                    validate: true,
                    required: false,
                  ),
                ],
              ),
              InsetGroup(
                footer:
                    'Vos documents sont vérifiés par l’équipe VITE. Si vous acceptez l’invitation d’une entreprise de livraison, votre dossier lui est aussi partagé, tant que vous y êtes rattaché. Ils sont supprimés si votre compte est fermé.',
                children: [
                  GroupSwitch(
                    title: 'J’accepte que VITE vérifie mes documents',
                    value: _consent,
                    onChanged: (v) {
                      if (e) setState(() => _consent = v);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusCard(Palette p, int done, int total) {
    final (
      IconData icon,
      Color color,
      String title,
      String text,
    ) = switch (_status) {
      'PENDING' => (
        PhosphorIconsBold.hourglassMedium,
        p.blue,
        'Dossier en cours de vérification',
        'VITE vérifie votre identité et votre engin. Vous serez prévenu ici dès que c’est fait.',
      ),
      'REJECTED' => (
        PhosphorIconsFill.prohibit,
        p.red,
        'Dossier à corriger',
        _d['reviewNote'] ?? 'Corrigez votre dossier puis renvoyez-le.',
      ),
      'SUSPENDED' => (
        PhosphorIconsFill.pauseCircle,
        p.red,
        'Compte suspendu',
        _d['reviewNote'] ?? 'Contactez VITE.',
      ),
      'APPROVED' => (
        PhosphorIconsFill.sealCheck,
        p.green,
        'Dossier validé',
        'Vous pouvez prendre des courses de livreur indépendant.',
      ),
      _ => (
        PhosphorIconsFill.clipboardText,
        accent,
        'Complétez votre dossier',
        '$done/$total éléments · toutes les photos se prennent avec l’appareil photo.',
      ),
    };
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
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
                if (_status == 'PENDING')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TintedButton(
                      'Actualiser',
                      icon: PhosphorIconsBold.arrowsClockwise,
                      onPressed: _reload,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String placeholder,
    IconData icon, {
    bool required = false,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) => IgnorePointer(
    ignoring: !_editable,
    child: GroupField(
      controller: c,
      placeholder: placeholder,
      icon: icon,
      keyboardType: keyboard,
      validator:
          validator ??
          (required
              ? (v) => (v ?? '').trim().isEmpty ? 'Obligatoire' : null
              : null),
    ),
  );

  Widget _section(
    Palette p,
    String header,
    List<(String, String, String?, bool)> items,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
          child: Text(
            header.toUpperCase(),
            style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final w = (c.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final it in items)
                  SizedBox(width: w, child: _photoTile(p, it)),
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _photoTile(Palette p, (String, String, String?, bool) it) {
    final (key, label, help, front) = it;
    final local = _local[key];
    final link = (_d['links'] as Map?)?[key] as String?;
    final busy = _uploading.contains(key);
    final has = local != null || link != null;
    return Pressable(
      onTap: !_editable || busy
          ? null
          : () async {
              if (help != null && !has) {
                final ok = await confirm(
                  context,
                  label,
                  message: help,
                  ok: 'Prendre la photo',
                );
                if (!ok) return;
              }
              _capture(key, front);
            },
      child: Container(
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (local != null)
                    Image.file(local, fit: BoxFit.cover)
                  else if (link != null)
                    Image.network(
                      photoUrl(link),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(color: p.fill),
                    )
                  else
                    Container(
                      color: p.fill,
                      child: Icon(
                        front
                            ? PhosphorIconsBold.userCircle
                            : PhosphorIconsFill.camera,
                        color: accent,
                        size: 30,
                      ),
                    ),
                  if (busy)
                    Container(
                      color: Colors.black38,
                      child: const Center(
                        child: CupertinoActivityIndicator(color: Colors.white),
                      ),
                    ),
                  if (has && !busy)
                    const Positioned(
                      right: 6,
                      top: 6,
                      child: Icon(
                        PhosphorIconsFill.checkCircle,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              child: Text(
                label,
                maxLines: 2,
                style: TextStyles.footnote.copyWith(
                  color: p.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// Solde prépayé
// ======================================================================

/// Solde du livreur indépendant : commission prélevée à chaque course, recharges Mobile Money
class IndependentBalanceScreen extends StatefulWidget {
  const IndependentBalanceScreen({super.key});
  @override
  State<IndependentBalanceScreen> createState() =>
      _IndependentBalanceScreenState();
}

class _IndependentBalanceScreenState extends State<IndependentBalanceScreen> {
  final api = Api.instance;
  Map<String, dynamic>? _b;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await api.myBalance();
      if (mounted) setState(() => _b = b);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _topup() async {
    final ok = await Navigator.push<bool>(
      context,
      CupertinoPageRoute(
        builder: (_) => _TopupScreen(config: (_b?['config'] as Map?) ?? {}),
      ),
    );
    if (ok == true && mounted) {
      showInfo(context, 'Recharge envoyée : VITE la vérifie au plus vite');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = _b;
    final tx = ((b?['transactions'] as List?) ?? []).cast<Map>();
    final pending = ((b?['payments'] as List?) ?? [])
        .cast<Map>()
        .where((x) => x['status'] == 'PENDING')
        .toList();
    return LargeTitlePage(
      title: 'Mon solde',
      onRefresh: _load,
      bottomBar: GlassBottomBar(
        child: FilledButton.icon(
          onPressed: b == null ? null : _topup,
          icon: const Icon(PhosphorIconsFill.plusCircle, size: 20),
          label: const Text('Recharger mon solde'),
        ),
      ),
      children: [
        if (b == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          )
        else ...[
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            padding: const EdgeInsets.all(18),
            decoration: ShapeDecoration(
              color: ink,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Disponible',
                  style: TextStyles.subheadline.copyWith(color: Colors.white70),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatMoney(b['available'] ?? 0),
                    style: TextStyles.largeTitle.copyWith(color: Colors.white),
                  ),
                ),
                Text(
                  'Solde ${formatMoney(b['credit'] ?? 0)} · réservé ${formatMoney(b['reserved'] ?? 0)} · commission ${b['rule']?['label'] ?? ''} par course',
                  style: TextStyles.footnote.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
          if (pending.isNotEmpty)
            InsetGroup(
              header: 'Recharges en attente',
              children: [
                for (final x in pending)
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.hourglassMedium,
                      color: p.blue,
                      size: 20,
                    ),
                    title: '${x['operator']} · ${formatMoney(x['amount'])}',
                    subtitle: 'En cours de vérification par VITE',
                  ),
              ],
            ),
          InsetGroup(
            header: 'Mouvements',
            footer:
                'Les commissions (VITE et votre entreprise) sont réservées quand vous acceptez une course et prélevées à la fin de la tournée.',
            children: tx.isEmpty
                ? [const GroupRow(title: 'Aucun mouvement pour le moment')]
                : [
                    for (final t in tx.take(50))
                      GroupRow(
                        title: switch (t['type']) {
                          'TOPUP' => 'Recharge',
                          'COMMISSION' => 'Commission',
                          'REFUND' => 'Remboursement (litige)',
                          'AFFILIATE_COMMISSION' =>
                            'Commission de votre entreprise',
                          _ => 'Correction VITE',
                        },
                        subtitle: [
                          if ((t['note'] ?? '').toString().isNotEmpty)
                            t['note'],
                          _when(t['createdAt']),
                        ].join(' · '),
                        value:
                            '${(t['amount'] as num) > 0 ? '+' : ''}${formatMoney(t['amount'])}',
                      ),
                  ],
          ),
        ],
      ],
    );
  }

  String _when(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Recharge : montant envoyé sur un compte Mobile Money de VITE + capture de la preuve
class _TopupScreen extends StatefulWidget {
  final Map config;
  const _TopupScreen({required this.config});
  @override
  State<_TopupScreen> createState() => _TopupScreenState();
}

class _TopupScreenState extends State<_TopupScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController(text: '5000');
  late final _sender = PhoneController(api.user?['phone']);
  final _reference = TextEditingController();
  late String _operator =
      ((widget.config['accounts'] as List?)
              ?.cast<Map>()
              .firstOrNull?['operator']
          as String?) ??
      'Wave';
  File? _proofFile;
  String? _proof;
  bool _sending = false;

  Future<void> _pickProof() async {
    final source = await showActions<ImageSource>(
      context,
      title: 'Preuve du paiement',
      message: 'Capture d’écran ou photo du message de confirmation',
      actions: [
        ('Choisir une capture', ImageSource.gallery, false),
        ('Prendre une photo', ImageSource.camera, false),
      ],
    );
    if (source == null) return;
    final f = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 75,
    );
    if (f == null || !mounted) return;
    setState(() => _proofFile = File(f.path));
    try {
      final url = await api.upload(File(f.path));
      if (mounted) setState(() => _proof = url);
    } catch (e) {
      if (mounted) {
        setState(() => _proofFile = null);
        showError(context, e);
      }
    }
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    if (_proof == null) {
      showError(context, 'Ajoutez la preuve du paiement');
      return;
    }
    setState(() => _sending = true);
    try {
      await api.requestTopup({
        'amount': int.parse(_amount.text.replaceAll(RegExp(r'\D'), '')),
        'operator': _operator,
        'senderPhone': _sender.e164,
        if (_reference.text.trim().isNotEmpty)
          'reference': _reference.text.trim(),
        'proofUrl': _proof,
      });
      hapticSuccess();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final accounts = ((widget.config['accounts'] as List?) ?? []).cast<Map>();
    final operators =
        ((widget.config['operators'] as List?) ??
                ['Wave', 'Orange Money', 'MTN MoMo', 'Moov Money'])
            .cast<String>();
    return LargeTitlePage(
      title: 'Recharger',
      inline: true,
      bottomBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? 'Envoi…' : 'Envoyer la recharge'),
        ),
      ),
      children: [
        InsetGroup(
          header: '1. Envoyez l’argent à VITE',
          children: accounts.isEmpty
              ? [
                  const GroupRow(
                    title: 'Comptes VITE bientôt disponibles : contactez VITE',
                  ),
                ]
              : [
                  for (final a in accounts)
                    GroupRow(
                      leading: Icon(
                        PhosphorIconsFill.money,
                        color: accent,
                        size: 20,
                      ),
                      title: '${a['operator']} · ${a['number']}',
                      subtitle: a['name'],
                    ),
                ],
        ),
        Form(
          key: _form,
          child: InsetGroup(
            header: '2. Déclarez le paiement',
            children: [
              GroupRow(
                title: 'Opérateur',
                value: _operator,
                chevron: true,
                onTap: () async {
                  final v = await showActions<String>(
                    context,
                    title: 'Opérateur',
                    actions: [for (final o in operators) (o, o, false)],
                  );
                  if (v != null && mounted) setState(() => _operator = v);
                },
              ),
              GroupField(
                controller: _amount,
                placeholder: 'Montant (${currencyLabel()})',
                icon: PhosphorIconsBold.money,
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (int.tryParse((v ?? '').replaceAll(RegExp(r'\D'), '')) ??
                            0) <
                        500
                    ? '${formatMoney(500)} minimum'
                    : null,
              ),
              PhoneField(
                controller: _sender,
                placeholder: 'Numéro qui a envoyé',
                validate: true,
              ),
              GroupField(
                controller: _reference,
                placeholder: 'Référence de la transaction (facultatif)',
                icon: PhosphorIconsBold.hash,
              ),
              GroupRow(
                leading: _proofFile != null
                    ? ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          _proofFile!,
                          width: 32,
                          height: 32,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Icon(PhosphorIconsFill.image, color: accent, size: 20),
                title: _proof != null
                    ? 'Preuve ajoutée'
                    : _proofFile != null
                    ? 'Envoi…'
                    : 'Ajouter la preuve du paiement',
                titleColor: _proof != null ? p.green : accent,
                onTap: _pickProof,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ======================================================================
// Rattachement à une entreprise de livraison
// ======================================================================

/// « Mon entreprise » : entreprise de rattachement, invitations reçues, nouveau taux à accepter
class AffiliationScreen extends StatefulWidget {
  const AffiliationScreen({super.key});
  @override
  State<AffiliationScreen> createState() => _AffiliationScreenState();
}

class _AffiliationScreenState extends State<AffiliationScreen> {
  final api = Api.instance;
  Map<String, dynamic>? _a;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    Realtime.instance.socket.on('affiliation:changed', _onChanged);
  }

  @override
  void dispose() {
    Realtime.instance.socket.off('affiliation:changed', _onChanged);
    super.dispose();
  }

  void _onChanged(dynamic _) => _load();

  Future<void> _load() async {
    try {
      final a = await api.myAffiliation();
      if (mounted) setState(() => _a = a);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _rate(dynamic type, dynamic value) => type == 'PERCENT'
      ? '${value is num && value == value.roundToDouble() ? value.toInt() : value} %'
      : formatMoney(value ?? 0);

  Future<void> _act(
    Future<Map<String, dynamic>> Function() action,
    String done,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final a = await action();
      if (!mounted) return;
      hapticSuccess();
      setState(() => _a = a);
      showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(Map inv) async {
    final join = inv['kind'] == 'JOIN';
    final ok = await showActions<bool>(
      context,
      title: join
          ? 'Rejoindre ${inv['companyName']} ?'
          : 'Accepter la nouvelle commission ?',
      message: join
          ? 'L’entreprise devient responsable de vous et prélève ${_rate(inv['commissionType'], inv['commissionValue'])} par course sur votre solde, en plus de la commission VITE.\n\nEn rejoignant ${inv['companyName']}, vous lui partagez votre dossier complet : téléphone, pièce d’identité, permis, carte grise, assurance et photos. Le partage s’arrête si vous la quittez (possible à tout moment, hors course en cours).'
          : '${inv['companyName']} prélèvera ${_rate(inv['commissionType'], inv['commissionValue'])} par course sur votre solde.',
      actions: [(join ? 'Rejoindre' : 'Accepter', true, false)],
    );
    if (ok != true) return;
    await _act(
      () => api.acceptInvite(inv['id']),
      join
          ? 'Vous êtes rattaché à ${inv['companyName']}'
          : 'Nouvelle commission acceptée',
    );
  }

  Future<void> _decline(Map inv) => _act(
    () => api.declineInvite(inv['id']),
    inv['kind'] == 'JOIN'
        ? 'Invitation refusée'
        : 'Vous gardez l’ancienne commission',
  );

  Future<void> _leave(Map aff) async {
    final reason = await prompt(
      context,
      'Quitter ${aff['companyName']} ?',
      message:
          'Vous ne recevrez plus de courses tant qu’une autre entreprise ne vous aura pas rattaché.',
      placeholder: 'Motif (facultatif)',
      ok: 'Quitter',
    );
    if (reason == null) return;
    await _act(
      () => api.leaveCompany(
        reason: reason.trim().isEmpty ? null : reason.trim(),
      ),
      'Vous avez quitté ${aff['companyName']}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = _a;
    final aff = a?['affiliation'] as Map?;
    final invites = ((a?['invites'] as List?) ?? []).cast<Map>();
    final joins = invites.where((i) => i['kind'] == 'JOIN').toList();
    final rates = invites.where((i) => i['kind'] == 'RATE').toList();
    final legacy = DateTime.tryParse(a?['legacyUntil'] ?? '')?.toLocal();
    final platform = a?['platformRate'] as Map?;
    return LargeTitlePage(
      title: 'Mon entreprise',
      onRefresh: _load,
      children: [
        if (a == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          )
        else ...[
          if (aff == null)
            InsetGroup(
              footer: legacy != null && legacy.isAfter(DateTime.now())
                  ? 'Vous pouvez encore travailler seul jusqu’au ${legacy.day.toString().padLeft(2, '0')}/${legacy.month.toString().padLeft(2, '0')}/${legacy.year}. Après cette date, il faudra être rattaché à une entreprise pour recevoir des courses.'
                  : 'Pour recevoir des courses, rattachez-vous à une entreprise de livraison : les entreprises voient votre profil validé par VITE et peuvent vous inviter.',
              children: [
                GroupRow(
                  leading: IconBadge(
                    PhosphorIconsFill.buildings,
                    color: p.yellow,
                  ),
                  title: 'Aucune entreprise',
                  subtitle: joins.isEmpty
                      ? 'En attente d’une invitation'
                      : '${joins.length} invitation(s) reçue(s)',
                ),
              ],
            )
          else
            InsetGroup(
              header: 'Rattaché à',
              footer:
                  'Votre entreprise est responsable de vous. Sa commission et celle de VITE${platform == null ? '' : ' (${_rate(platform['type'], platform['value'])})'} sont prélevées sur votre solde à la fin de chaque course.',
              children: [
                GroupRow(
                  leading: const IconBadge(
                    PhosphorIconsFill.buildings,
                    color: accent,
                  ),
                  title: aff['companyName'] ?? '',
                  subtitle: aff['since'] == null
                      ? null
                      : 'Depuis le ${_date(aff['since'])}',
                  trailing: CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () => launchUrl(telUri(aff['companyPhone'])),
                    child: Icon(
                      PhosphorIconsFill.phone,
                      color: p.green,
                      size: 22,
                    ),
                  ),
                ),
                GroupRow(
                  leading: Icon(
                    PhosphorIconsBold.tag,
                    color: p.secondaryLabel,
                    size: 20,
                  ),
                  title: 'Commission de l’entreprise',
                  value:
                      '${_rate(aff['rateType'], aff['rateValue'])} par course',
                ),
                GroupRow(
                  leading: Icon(
                    PhosphorIconsBold.handCoins,
                    color: p.secondaryLabel,
                    size: 20,
                  ),
                  title: 'Paiement à la livraison',
                  subtitle: aff['codAllowed'] == true
                      ? 'Versez les montants encaissés à votre entreprise'
                      : null,
                  value: aff['codAllowed'] == true
                      ? 'Autorisé'
                      : 'Non autorisé',
                ),
              ],
            ),
          for (final inv in rates)
            _InviteCard(
              title: 'Nouvelle commission proposée',
              subtitle:
                  '${inv['companyName']} propose ${_rate(inv['commissionType'], inv['commissionValue'])} par course. En attendant votre réponse, l’ancienne commission s’applique.',
              busy: _busy,
              acceptLabel: 'Accepter',
              declineLabel: 'Garder l’ancienne',
              onAccept: () => _accept(inv),
              onDecline: () => _decline(inv),
            ),
          if (aff == null)
            for (final inv in joins)
              _InviteCard(
                title: inv['companyName'] ?? '',
                subtitle: [
                  'Commission : ${_rate(inv['commissionType'], inv['commissionValue'])} par course',
                  if ((inv['drivers'] ?? 0) > 0) '${inv['drivers']} livreurs',
                  if ((inv['message'] ?? '').toString().isNotEmpty)
                    '« ${inv['message']} »',
                ].join(' · '),
                note:
                    'En rejoignant cette entreprise, vous lui partagez votre dossier complet (pièce d’identité, permis, carte grise, assurance, photos).',
                busy: _busy,
                acceptLabel: 'Rejoindre',
                declineLabel: 'Refuser',
                onAccept: () => _accept(inv),
                onDecline: () => _decline(inv),
              ),
          if (aff != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: TintedButton(
                'Quitter cette entreprise',
                icon: PhosphorIconsBold.signOut,
                onPressed: _busy ? null : () => _leave(aff),
              ),
            ),
        ],
      ],
    );
  }

  String _date(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}

class _InviteCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool busy;
  final String acceptLabel;
  final String declineLabel;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final String? note;
  const _InviteCard({
    this.note,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.acceptLabel,
    required this.declineLabel,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconBadge(PhosphorIconsFill.envelopeSimple, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  PhosphorIconsBold.shieldCheck,
                  size: 16,
                  color: p.secondaryLabel,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    note!,
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TintedButton(
                  declineLabel,
                  onPressed: busy ? null : onDecline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: primaryButton,
                    foregroundColor: onPrimaryButton,
                  ),
                  onPressed: busy ? null : onAccept,
                  child: Text(acceptLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
