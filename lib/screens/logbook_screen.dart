import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import 'order_screen.dart' show normalizePhone;
import 'widgets.dart';

/// Dev / tests : photo déjà envoyée utilisée à la place de l'appareil photo
const _devPhoto = String.fromEnvironment('DEV_PHOTO');

/// Statuts d'une livraison du carnet : libellé et couleur
(String, Color) logbookStatus(String s, Palette p) => switch (s) {
  'DELIVERED' => ('Livrée', p.green),
  'FAILED' => ('Non livrée', p.red),
  'CANCELLED' => ('Annulée', p.secondaryLabel),
  _ => ('À livrer', p.blue),
};

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  if (_sameDay(d, now)) return 'Aujourd’hui';
  if (_sameDay(d, now.subtract(const Duration(days: 1)))) return 'Hier';
  const days = [
    'lundi',
    'mardi',
    'mercredi',
    'jeudi',
    'vendredi',
    'samedi',
    'dimanche',
  ];
  const months = [
    'janv.',
    'févr.',
    'mars',
    'avr.',
    'mai',
    'juin',
    'juil.',
    'août',
    'sept.',
    'oct.',
    'nov.',
    'déc.',
  ];
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Onglet « Carnet » du livreur : il remplace le bout de papier.
/// Chaque livraison : adresse, numéro du destinataire, prix et photo du colis.
class DriverLogbook extends StatefulWidget {
  const DriverLogbook({super.key});
  @override
  State<DriverLogbook> createState() => _DriverLogbookState();
}

class _DriverLogbookState extends State<DriverLogbook> {
  final api = Api.instance;
  List<Map<String, dynamic>>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await api.logbook(
        from: DateTime.now().subtract(const Duration(days: 30)),
      );
      if (mounted) setState(() => _entries = l.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) {
        setState(() => _entries ??= []);
        showError(context, e);
      }
    }
  }

  void _replace(Map<String, dynamic> e) {
    final l = [...?_entries];
    final i = l.indexWhere((x) => x['id'] == e['id']);
    i < 0 ? l.insert(0, e) : l[i] = e;
    setState(() => _entries = l);
  }

  Future<void> _new() async {
    final e = await Navigator.of(context).push<Map<String, dynamic>>(
      CupertinoPageRoute(builder: (_) => const LogbookEntryScreen()),
    );
    if (e != null && mounted) {
      _replace(e);
      hapticSuccess();
      showInfo(context, 'Livraison enregistrée dans votre carnet');
    }
  }

  Future<void> _actions(Map<String, dynamic> e) async {
    final todo = e['status'] == 'TODO';
    final a = await showActions<String>(
      context,
      title: e['address'],
      message:
          '${e['recipientName'] ?? 'Destinataire'} · ${e['recipientPhone']} · ${fcfa(e['price'])}',
      actions: [
        if (todo) ('Livrée', 'DELIVERED', false),
        if (todo) ('Non livrée (absent, refus…)', 'FAILED', false),
        ('Appeler le destinataire', 'call', false),
        ('Voir la photo du colis', 'photo', false),
        if (e['status'] != 'CANCELLED') ('Modifier', 'edit', false),
        if (!todo) ('Remettre « à livrer »', 'TODO', false),
        if (todo) ('Annuler cette livraison', 'CANCELLED', true),
      ],
    );
    if (a == null || !mounted) return;
    switch (a) {
      case 'call':
        await launchUrl(Uri(scheme: 'tel', path: e['recipientPhone']));
      case 'photo':
        await showDialog(
          context: context,
          builder: (_) => Dialog(
            child: InteractiveViewer(
              child: Image.network(photoUrl(e['photoUrl'])),
            ),
          ),
        );
      case 'edit':
        final r = await Navigator.of(context).push<Map<String, dynamic>>(
          CupertinoPageRoute(builder: (_) => LogbookEntryScreen(entry: e)),
        );
        if (r != null && mounted) {
          _replace(r);
          showInfo(
            context,
            'Modification enregistrée (visible par votre entreprise)',
          );
        }
      default:
        String? note;
        if (a == 'FAILED' || a == 'CANCELLED') {
          note = await prompt(
            context,
            a == 'FAILED' ? 'Non livrée' : 'Annuler la livraison',
            message: 'Motif (facultatif)',
            placeholder: a == 'FAILED'
                ? 'Ex. : absent, ne répond pas'
                : 'Ex. : commande annulée',
            ok: 'Valider',
          );
          if (note == null) return;
        }
        try {
          final r = await api.setLogbookStatus(
            e['id'],
            a,
            note: (note ?? '').trim().isEmpty ? null : note!.trim(),
          );
          if (!mounted) return;
          a == 'DELIVERED' ? hapticSuccess() : hapticTap();
          _replace(r);
        } catch (err) {
          if (mounted) showError(context, err);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final list = _entries;
    final now = DateTime.now();
    final today = (list ?? [])
        .where((e) => _sameDay(DateTime.parse(e['createdAt']).toLocal(), now))
        .toList();
    final deliveredToday = today.where((e) => e['status'] == 'DELIVERED');
    final amount = deliveredToday.fold<num>(
      0,
      (s, e) => s + (e['price'] as num),
    );
    final todo = (list ?? []).where((e) => e['status'] == 'TODO').toList();
    final done = (list ?? []).where((e) => e['status'] != 'TODO').toList();

    // Livraisons traitées, groupées par jour
    final days = <String, List<Map<String, dynamic>>>{};
    for (final e in done) {
      final d = DateTime.parse(e['createdAt']).toLocal();
      days.putIfAbsent(_dayLabel(d), () => []).add(e);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(
            'Mon carnet',
            style: TextStyles.title1.copyWith(color: p.label),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Text(
            'Vos livraisons hors application, sans papier : votre entreprise les voit aussi.',
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
        ),
        // ----- Résumé du jour -----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _stat(p, '${today.length}', 'Aujourd’hui'),
              const SizedBox(width: 10),
              _stat(p, '${deliveredToday.length}', 'Livrées'),
              const SizedBox(width: 10),
              _stat(p, fcfa(amount), 'Montant', wide: true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: FilledButton.icon(
            onPressed: _new,
            icon: const Icon(CupertinoIcons.camera_fill, size: 20),
            label: const Text('Nouvelle livraison'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ),
        if (list == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: CupertinoActivityIndicator(),
          )
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
            child: Column(
              children: [
                Icon(CupertinoIcons.book, size: 40, color: p.tertiaryLabel),
                const SizedBox(height: 8),
                Text(
                  'Aucune livraison dans le carnet.\nPrenez le colis en photo, notez l’adresse, le numéro et le prix.',
                  textAlign: TextAlign.center,
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (todo.isNotEmpty)
            InsetGroup(
              header: 'À livrer (${todo.length})',
              children: [for (final e in todo) _tile(p, e)],
            ),
          for (final MapEntry(key: day, value: items) in days.entries)
            InsetGroup(
              header:
                  '$day · ${items.where((e) => e['status'] == 'DELIVERED').length} livrée(s)',
              children: [for (final e in items) _tile(p, e)],
            ),
        ],
      ],
    );
  }

  Widget _stat(Palette p, String value, String label, {bool wide = false}) =>
      Expanded(
        flex: wide ? 2 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: ShapeDecoration(
            color: p.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyles.title2.copyWith(color: p.label),
                ),
              ),
              Text(
                label,
                style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
              ),
            ],
          ),
        ),
      );

  Widget _tile(Palette p, Map<String, dynamic> e) {
    final (label, color) = logbookStatus(e['status'], p);
    final at = DateTime.parse(e['createdAt']).toLocal();
    return InkWell(
      onTap: () {
        hapticTap();
        _actions(e);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            AddressPhoto(e['photoUrl'], size: 54),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e['address'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.headline.copyWith(color: p.label),
                  ),
                  Text(
                    '${e['recipientName'] ?? 'Sans nom'} · ${e['recipientPhone']} · ${_hm(at)}',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  fcfa(e['price']),
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
                const SizedBox(height: 4),
                Pill(label, color: color),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Saisie (ou modification) d'une livraison du carnet.
/// La photo du colis se prend avec l'appareil photo uniquement (pas de photothèque).
class LogbookEntryScreen extends StatefulWidget {
  final Map<String, dynamic>? entry;
  const LogbookEntryScreen({super.key, this.entry});
  @override
  State<LogbookEntryScreen> createState() => _LogbookEntryScreenState();
}

class _LogbookEntryScreenState extends State<LogbookEntryScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();
  late final _address = TextEditingController(text: widget.entry?['address']);
  late final _phone = TextEditingController(
    text: widget.entry?['recipientPhone'],
  );
  late final _name = TextEditingController(
    text: widget.entry?['recipientName'],
  );
  late final _price = TextEditingController(
    text: widget.entry?['price']?.toString(),
  );
  late final _note = TextEditingController(text: widget.entry?['note']);
  late String? _photo = widget.entry?['photoUrl'];
  File? _localPhoto;
  bool _uploading = false;
  bool _saving = false;
  bool _locating = false;
  LatLng? _pos;

  bool get _editing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    // Position au moment de la saisie (aide l'entreprise à situer la livraison)
    if (!_editing) myPosition().then((p) => _pos = p).catchError((_) => null);
  }

  Future<void> _takePhoto() async {
    if (_devPhoto.isNotEmpty) {
      setState(() => _photo = _devPhoto);
      return;
    }
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera, // appareil photo seulement
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (file == null || !mounted) return;
    setState(() {
      _localPhoto = File(file.path);
      _uploading = true;
    });
    try {
      final url = await api.upload(File(file.path));
      if (mounted) setState(() => _photo = url);
    } catch (e) {
      if (mounted) {
        setState(() => _localPhoto = null);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _useMyPosition() async {
    setState(() => _locating = true);
    try {
      final p = await myPosition();
      if (p == null)
        throw ApiException('Position indisponible : activez la localisation');
      _pos = p;
      final place = await api.reverse(p);
      if (mounted) {
        _address.text = [
          place.label,
          place.sublabel,
        ].where((s) => s.isNotEmpty).join(', ');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickContact() async {
    try {
      final c = await FlutterNativeContactPicker().selectPhoneNumber();
      if (c == null || !mounted) return;
      final raw =
          c.selectedPhoneNumber ??
          (c.phoneNumbers?.isNotEmpty == true ? c.phoneNumbers!.first : '');
      final phone = normalizePhone(raw);
      setState(() {
        if (phone.isNotEmpty) _phone.text = phone;
        if ((c.fullName ?? '').trim().isNotEmpty && _name.text.trim().isEmpty) {
          _name.text = c.fullName!.trim();
        }
      });
    } catch (_) {
      if (mounted) showError(context, 'Répertoire indisponible');
    }
  }

  Future<void> _save() async {
    if (!_editing && _photo == null) {
      showError(
        context,
        _uploading ? 'Photo en cours d’envoi…' : 'Prenez le colis en photo',
      );
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'address': _address.text.trim(),
        'recipientPhone': normalizePhone(_phone.text),
        'recipientName': _name.text.trim(),
        'price': int.parse(_price.text.replaceAll(RegExp(r'\D'), '')),
        'note': _note.text.trim(),
      };
      final r = _editing
          ? await api.updateLogbookEntry(widget.entry!['id'], body)
          : await api.addLogbookEntry({
              ...body,
              'photoUrl': _photo,
              if (_pos != null) 'lat': _pos!.latitude,
              if (_pos != null) 'lng': _pos!.longitude,
            });
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LargeTitlePage(
      title: _editing ? 'Modifier la livraison' : 'Nouvelle livraison',
      inline: true,
      bottomBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _saving || _uploading ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: Text(
            _saving ? 'Enregistrement…' : 'Enregistrer dans le carnet',
          ),
        ),
      ),
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ----- Photo du colis -----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
                child: _photoBox(p),
              ),
              InsetGroup(
                header: 'Adresse de livraison',
                children: [
                  GroupField(
                    controller: _address,
                    placeholder: 'Quartier, rue, repère…',
                    icon: CupertinoIcons.location_solid,
                    maxLines: 3,
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Adresse obligatoire' : null,
                  ),
                  if (!_editing)
                    GroupRow(
                      leading: Icon(
                        CupertinoIcons.location,
                        color: accent,
                        size: 20,
                      ),
                      title: _locating
                          ? 'Localisation…'
                          : 'Je suis à l’adresse : utiliser ma position',
                      titleColor: accent,
                      onTap: _locating ? null : _useMyPosition,
                    ),
                ],
              ),
              InsetGroup(
                header: 'Destinataire',
                children: [
                  GroupField(
                    controller: _phone,
                    placeholder: 'Numéro (10 chiffres)',
                    icon: CupertinoIcons.phone_fill,
                    keyboardType: TextInputType.phone,
                    validator: (v) =>
                        RegExp(r'^0\d{9}$').hasMatch(normalizePhone(v ?? ''))
                        ? null
                        : 'Numéro à 10 chiffres, ex : 0701020304',
                  ),
                  GroupRow(
                    leading: Icon(
                      CupertinoIcons.person_crop_circle,
                      color: accent,
                      size: 20,
                    ),
                    title: 'Choisir dans le répertoire',
                    titleColor: accent,
                    onTap: _pickContact,
                  ),
                  GroupField(
                    controller: _name,
                    placeholder: 'Nom (facultatif)',
                    icon: CupertinoIcons.person_fill,
                  ),
                ],
              ),
              InsetGroup(
                header: 'Prix de la livraison',
                children: [
                  GroupField(
                    controller: _price,
                    placeholder: 'Montant en F CFA',
                    icon: CupertinoIcons.money_dollar_circle_fill,
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse(
                        (v ?? '').replaceAll(RegExp(r'\D'), ''),
                      );
                      return n == null ? 'Prix obligatoire' : null;
                    },
                  ),
                ],
              ),
              InsetGroup(
                header: 'Note',
                footer: _editing
                    ? 'Chaque modification est gardée dans l’historique, visible par votre entreprise.'
                    : 'Votre entreprise voit cette livraison et son historique.',
                children: [
                  GroupField(
                    controller: _note,
                    placeholder:
                        'Ex. : colis fragile, payer à la livraison… (facultatif)',
                    icon: CupertinoIcons.text_bubble_fill,
                    maxLines: 3,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoBox(Palette p) {
    final has = _localPhoto != null || _photo != null;
    final image = _localPhoto != null
        ? Image.file(_localPhoto!, fit: BoxFit.cover)
        : _photo != null
        ? Image.network(
            photoUrl(_photo!),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(color: p.fill),
          )
        : null;
    return Pressable(
      onTap: _editing || _uploading ? null : _takePhoto,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 210,
          color: has ? p.fill : p.card,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ?image,
              if (!has)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: ShapeDecoration(
                        gradient: letoGradient,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Icon(
                        CupertinoIcons.camera_fill,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Prendre le colis en photo',
                      style: TextStyles.headline.copyWith(color: p.label),
                    ),
                    Text(
                      'Obligatoire · appareil photo uniquement',
                      style: TextStyles.footnote.copyWith(
                        color: p.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              if (_uploading)
                Container(
                  color: Colors.black38,
                  child: const Center(
                    child: CupertinoActivityIndicator(color: Colors.white),
                  ),
                ),
              if (has && !_editing && !_uploading)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: ShapeDecoration(
                      color: Colors.black54,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.camera_rotate,
                          color: Colors.white,
                          size: 16,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Reprendre',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
