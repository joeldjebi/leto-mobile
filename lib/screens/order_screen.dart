import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import '../models.dart';
import 'widgets.dart';

/// Détails de la commande : délai, départ, un bloc par destinataire, commentaire.
class OrderScreen extends StatefulWidget {
  final Place pickup;
  final List<StopDraft> stops;
  final Map<String, dynamic> quote;
  final String vehicle;
  const OrderScreen({
    super.key,
    required this.pickup,
    required this.stops,
    required this.quote,
    required this.vehicle,
  });

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

/// Champs d'un destinataire
class _StopForm {
  final StopDraft draft;
  final name = TextEditingController();
  final phone = TextEditingController();
  final details = TextEditingController();
  final description = TextEditingController();
  final cod = TextEditingController();
  bool codOn = false;
  String? photo;

  _StopForm(this.draft) {
    name.text = draft.name;
    phone.text = draft.phone;
    details.text = draft.details;
  }
}

class _OrderScreenState extends State<OrderScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();

  String _speed = 'STANDARD';
  bool _sending = false;
  String? _pickupPhoto;
  late final List<_StopForm> _forms = widget.stops.map(_StopForm.new).toList();

  final _pickupDetails = TextEditingController();
  late final _senderName = TextEditingController(text: api.user?['name']);
  late final _pickupPhone = TextEditingController(text: api.user?['phone']);
  final _comment = TextEditingController();

  Map<String, dynamic> get _offer => (widget.quote['offers'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((o) => o['vehicle'] == widget.vehicle);
  Map<String, dynamic> get _speeds =>
      widget.quote['speeds'] as Map<String, dynamic>;
  int get _codFee => widget.quote['codFee'] as int;
  int get _codStops => _forms.where((f) => f.codOn).length;
  int _priceFor(String speed) =>
      (_offer['prices'][speed] as int) + _codFee * _codStops;

  Future<void> _submit() async {
    // Vérification sur les données (les champs hors de l'écran ne sont pas construits)
    _form.currentState!.validate();
    final missing = _missing();
    if (missing != null) {
      showError(context, missing);
      return;
    }
    setState(() => _sending = true);
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final d = await api.createDelivery({
        'vehicleType': widget.vehicle,
        'speed': _speed,
        'pickupLat': widget.pickup.point.latitude,
        'pickupLng': widget.pickup.point.longitude,
        'pickupAddress': widget.pickup.label,
        'pickupDetails': ?opt(_pickupDetails),
        'pickupContactName': ?opt(_senderName),
        'pickupPhone': _pickupPhone.text.trim(),
        'pickupPhotoUrl': ?_pickupPhoto,
        'courierComment': ?opt(_comment),
        'stops': [
          for (final f in _forms)
            {
              'lat': f.draft.place.point.latitude,
              'lng': f.draft.place.point.longitude,
              'address': f.draft.place.label,
              'recipientName': f.name.text.trim(),
              'recipientPhone': f.phone.text.trim(),
              'details': ?opt(f.details),
              'packageDescription': ?opt(f.description),
              'photoUrl': ?f.photo,
              'codAmount': f.codOn
                  ? int.parse(f.cod.text.replaceAll(' ', ''))
                  : 0,
            },
        ],
      });
      hapticSuccess();
      if (mounted) Navigator.pop(context, d);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Premier champ manquant ou invalide, avec un message précis
  String? _missing() {
    final phoneOk = RegExp(r'^0\d{9}$');
    if (_senderName.text.trim().isEmpty) return 'Départ : indiquez le nom de l’expéditeur';
    if (!phoneOk.hasMatch(_pickupPhone.text.trim())) return 'Départ : téléphone invalide (10 chiffres)';
    for (var i = 0; i < _forms.length; i++) {
      final f = _forms[i];
      final who = _forms.length > 1 ? 'Destinataire ${i + 1}' : 'Destinataire';
      if (f.name.text.trim().isEmpty) return '$who : indiquez le nom';
      if (!phoneOk.hasMatch(f.phone.text.trim())) return '$who : téléphone invalide (10 chiffres)';
      if (f.codOn && (int.tryParse(f.cod.text.replaceAll(' ', '')) ?? 0) <= 0) return '$who : montant à encaisser';
    }
    return null;
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Obligatoire' : null;
  String? _phone(String? v) => RegExp(r'^0\d{9}$').hasMatch(v?.trim() ?? '')
      ? null
      : '10 chiffres, ex : 0701020304';
  String? _amount(String? v) {
    final n = int.tryParse((v ?? '').replaceAll(' ', ''));
    return (n == null || n <= 0) ? 'Montant à encaisser' : null;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = _forms.length;
    return Form(
      key: _form,
      child: LargeTitlePage(
        title: n > 1 ? 'Tournée · $n arrêts' : 'Détails',
        bottomBar: GlassBottomBar(
          child: Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total',
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
                  Text(
                    fcfa(_priceFor(_speed)),
                    style: TextStyles.title2.copyWith(color: p.label),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: _sending ? null : _submit,
                  child: _sending
                      ? const CupertinoActivityIndicator(color: Colors.white)
                      : const Text('Commander'),
                ),
              ),
            ],
          ),
        ),
        children: [
          // ----- Résumé -----
          InsetGroup(
            children: [
              GroupRow(
                leading: IconBadge(
                  vehicleIcons[widget.vehicle]!,
                  color: letoOrange,
                ),
                title: _offer['label'],
                subtitle:
                    '${km(widget.quote['distanceKm'])} · ~${widget.quote['durationMin']} min${n > 1 ? ' · ordre optimisé' : ''}',
              ),
            ],
          ),
          // ----- Délai -----
          InsetGroup(
            header: 'Délai',
            children: [
              for (final s in ['EXPRESS', 'STANDARD', 'SCHEDULED'])
                GroupRow(
                  title: _speeds[s]['label'],
                  subtitle: _speeds[s]['description'],
                  value: fcfa(_priceFor(s)),
                  trailing: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Icon(
                      CupertinoIcons.checkmark_alt,
                      color: _speed == s ? letoOrange : Colors.transparent,
                    ),
                  ),
                  onTap: () => setState(() => _speed = s),
                ),
            ],
          ),
          // ----- Départ -----
          InsetGroup(
            header: 'Départ',
            children: [
              GroupRow(
                leading: _dot('A', p.green),
                title: widget.pickup.label,
                subtitle: widget.pickup.sublabel,
              ),
              GroupField(
                controller: _pickupDetails,
                placeholder: 'Repère, étage, portail…',
                icon: CupertinoIcons.placemark,
              ),
              _PhotoRow(
                url: _pickupPhoto,
                onChanged: (u) => setState(() => _pickupPhoto = u),
              ),
              GroupField(
                controller: _senderName,
                placeholder: 'Expéditeur',
                icon: CupertinoIcons.person,
                validator: _required,
              ),
              GroupField(
                controller: _pickupPhone,
                placeholder: 'Téléphone',
                prefix: '+225',
                keyboardType: TextInputType.phone,
                validator: _phone,
              ),
            ],
          ),
          // ----- Destinataires -----
          for (var i = 0; i < n; i++) _stopSection(i, p),
          // ----- Coursier -----
          InsetGroup(
            header: 'Pour le coursier',
            children: [
              GroupField(
                controller: _comment,
                placeholder: 'Commentaire (facultatif)',
                icon: CupertinoIcons.chat_bubble,
                maxLines: 3,
              ),
            ],
          ),
          InsetGroup(
            footer:
                'La livraison est due même si un destinataire est absent (absence vérifiée : GPS, attente, photo).',
            children: [
              GroupRow(
                leading: IconBadge(CupertinoIcons.money_dollar, color: p.green),
                title: 'Espèces',
                subtitle: 'Payé au livreur',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot(String label, Color color) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    ),
  );

  Widget _stopSection(int i, Palette p) {
    final f = _forms[i];
    return InsetGroup(
      header: _forms.length > 1 ? 'Destinataire ${i + 1}' : 'Destinataire',
      children: [
        GroupRow(
          leading: _dot('${i + 1}', letoOrange),
          title: f.draft.place.label,
          subtitle: f.draft.place.sublabel,
        ),
        GroupField(
          controller: f.name,
          placeholder: 'Nom du destinataire',
          icon: CupertinoIcons.person,
          validator: _required,
        ),
        GroupField(
          controller: f.phone,
          placeholder: 'Téléphone',
          prefix: '+225',
          keyboardType: TextInputType.phone,
          validator: _phone,
        ),
        GroupField(
          controller: f.details,
          placeholder: 'Repère, étage, portail…',
          icon: CupertinoIcons.placemark,
        ),
        GroupField(
          controller: f.description,
          placeholder: 'Colis (facultatif)',
          icon: CupertinoIcons.cube_box,
        ),
        GroupSwitch(
          title: 'Paiement à la livraison',
          subtitle: 'Le livreur encaisse la marchandise · +${fcfa(_codFee)}',
          value: f.codOn,
          onChanged: (v) => setState(() => f.codOn = v),
        ),
        if (f.codOn)
          GroupField(
            controller: f.cod,
            placeholder: 'Montant à encaisser',
            icon: CupertinoIcons.creditcard,
            keyboardType: TextInputType.number,
            validator: _amount,
          ),
        _PhotoRow(url: f.photo, onChanged: (u) => setState(() => f.photo = u)),
      ],
    );
  }
}

/// Photo d'adresse : prise ou choisie, envoyée à l'API
class _PhotoRow extends StatefulWidget {
  final String? url;
  final ValueChanged<String?> onChanged;
  const _PhotoRow({required this.url, required this.onChanged});

  @override
  State<_PhotoRow> createState() => _PhotoRowState();
}

class _PhotoRowState extends State<_PhotoRow> {
  bool _uploading = false;

  Future<void> _pick() async {
    final source = await showActions<ImageSource>(
      context,
      title: 'Photo de l’adresse',
      actions: [
        ('Prendre une photo', ImageSource.camera, false),
        ('Choisir dans la photothèque', ImageSource.gallery, false),
      ],
    );
    if (source == null) return;
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        imageQuality: 70,
      );
      if (file == null) return;
      setState(() => _uploading = true);
      widget.onChanged(await Api.instance.upload(File(file.path)));
    } catch (e) {
      if (mounted) {
        showError(context, kDebugMode ? e : 'Impossible d’ajouter la photo');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (widget.url != null) {
      return GroupRow(
        leading: AddressPhoto(widget.url!, size: 44),
        title: 'Photo de l’adresse',
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => widget.onChanged(null),
          child: Text('Retirer', style: TextStyles.body.copyWith(color: p.red)),
        ),
      );
    }
    return GroupRow(
      leading: Icon(CupertinoIcons.camera, size: 20, color: p.secondaryLabel),
      title: 'Ajouter une photo (portail, devanture…)',
      titleColor: letoOrange,
      trailing: _uploading ? const CupertinoActivityIndicator() : null,
      onTap: _uploading ? null : _pick,
    );
  }
}
