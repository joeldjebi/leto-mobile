import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import '../models.dart';
import 'place_search.dart';
import 'widgets.dart';

/// Détails de la commande, réduits à l'essentiel : engin, délai, départ, destinataires.
/// Les adresses restent modifiables (le prix est recalculé) et on peut ajouter des arrêts.
class OrderScreen extends StatefulWidget {
  final Place pickup;
  final List<StopDraft>
  stops; // liste partagée avec l'accueil (modifiée sur place)
  final Map<String, dynamic> quote;
  final String vehicle;
  final ValueChanged<Place>? onPickupChanged;
  final ValueChanged<String>? onVehicleChanged;
  const OrderScreen({
    super.key,
    required this.pickup,
    required this.stops,
    required this.quote,
    required this.vehicle,
    this.onPickupChanged,
    this.onVehicleChanged,
  });

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

/// Champs d'un destinataire
class _StopForm {
  final name = TextEditingController();
  final phone = TextEditingController();
  final description = TextEditingController();
  final cod = TextEditingController();
  bool codOn = false;
  String? photo;

  _StopForm(StopDraft draft) {
    name.text = draft.name;
    phone.text = draft.phone;
    photo = draft.photo;
  }
}

class _OrderScreenState extends State<OrderScreen> {
  static const _maxStops = 10;
  final api = Api.instance;

  late Place _pickup = widget.pickup;
  late Map<String, dynamic> _quote = widget.quote;
  late String _vehicle = widget.vehicle;
  String _speed = 'STANDARD';
  bool _sending = false;
  bool _quoting = false;
  String? _pickupPhoto;

  List<StopDraft> get _stops => widget.stops;

  /// Formulaire de chaque arrêt (suit l'arrêt quand l'ordre de passage change)
  final _forms = <StopDraft, _StopForm>{};
  _StopForm _formOf(StopDraft d) => _forms.putIfAbsent(d, () => _StopForm(d));

  List<Map<String, dynamic>> get _offers =>
      (_quote['offers'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get _offer => _offers.firstWhere(
    (o) => o['vehicle'] == _vehicle,
    orElse: () => _offers.first,
  );
  Map<String, dynamic> get _speeds => _quote['speeds'] as Map<String, dynamic>;
  bool get _codEnabled => _quote['codEnabled'] == true;
  int get _codFee => _quote['codFee'] as int;
  int get _codStops =>
      _codEnabled ? _stops.where((s) => _formOf(s).codOn).length : 0;
  int _priceFor(String speed, [Map<String, dynamic>? offer]) =>
      ((offer ?? _offer)['prices'][speed] as int) + _codFee * _codStops;

  // ---------- Adresses ----------

  /// Nouveau devis après un changement d'adresse : prix, distance et ordre de passage
  Future<void> _requote() async {
    setState(() => _quoting = true);
    try {
      final q = await api.quote(_pickup.point, [
        for (final s in _stops) (point: s.place.point, cod: false),
      ]);
      if (!mounted) return;
      final order = (q['order'] as List).cast<int>();
      final reordered = [for (final i in order) _stops[i]];
      setState(() {
        _stops
          ..clear()
          ..addAll(reordered);
        _quote = q;
        if (!_offers.any((o) => o['vehicle'] == _vehicle)) {
          _vehicle = _offers.first['vehicle'];
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<Object?> _search(String title, {bool dropoff = false}) =>
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaceSearchScreen(
            title: title,
            near: _pickup.point,
            dropoff: dropoff,
            allowMap: false,
          ),
        ),
      );

  Future<void> _changePickup() async {
    final res = await _search('Départ');
    if (res is! Place || !mounted) return;
    setState(() => _pickup = res);
    widget.onPickupChanged?.call(res);
    _requote();
  }

  Future<void> _changeStop(StopDraft d) async {
    final res = await _search('Adresse de livraison', dropoff: true);
    if (!mounted) return;
    if (res is Place) {
      d.place = res;
    } else if (res is StopDraft) {
      // Destinataire du carnet : adresse et coordonnées
      d.place = res.place;
      final f = _formOf(d);
      if (f.name.text.trim().isEmpty) f.name.text = res.name;
      if (f.phone.text.trim().isEmpty) f.phone.text = res.phone;
      d.details = res.details;
    } else {
      return;
    }
    _requote();
  }

  Future<void> _addStop() async {
    final res = await _search('Nouvel arrêt', dropoff: true);
    if (!mounted) return;
    final draft = res is StopDraft
        ? res
        : (res is Place ? StopDraft(res) : null);
    if (draft == null) return;
    hapticTap();
    setState(() => _stops.add(draft));
    _requote();
  }

  Future<void> _removeStop(StopDraft d) async {
    if (!await confirm(
      context,
      'Retirer cet arrêt ?',
      ok: 'Retirer',
      destructive: true,
    ))
      return;
    setState(() {
      _stops.remove(d);
      _forms.remove(d);
    });
    _requote();
  }

  // ---------- Commande ----------

  Future<void> _submit() async {
    final missing = _missing();
    if (missing != null) {
      showError(context, missing);
      return;
    }
    setState(() => _sending = true);
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    String? optStr(String s) => s.trim().isEmpty ? null : s.trim();
    try {
      final d = await api.createDelivery({
        'vehicleType': _vehicle,
        'speed': _speed,
        'pickupLat': _pickup.point.latitude,
        'pickupLng': _pickup.point.longitude,
        'pickupAddress': _pickup.label,
        // Expéditeur : le profil du client (modifiable dans « Mon profil »)
        'pickupContactName': ?optStr(api.user?['name'] ?? ''),
        'pickupPhone': api.user?['phone'],
        'pickupPhotoUrl': ?_pickupPhoto,
        'stops': [
          for (final s in _stops)
            {
              'lat': s.place.point.latitude,
              'lng': s.place.point.longitude,
              'address': s.place.label,
              'recipientName': _formOf(s).name.text.trim(),
              'recipientPhone': _formOf(s).phone.text.trim(),
              'details': ?optStr(s.details),
              'packageDescription': ?opt(_formOf(s).description),
              'photoUrl': ?_formOf(s).photo,
              'codAmount': _codEnabled && _formOf(s).codOn
                  ? int.parse(_formOf(s).cod.text.replaceAll(' ', ''))
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
    for (var i = 0; i < _stops.length; i++) {
      final f = _formOf(_stops[i]);
      final who = _stops.length > 1 ? 'Destinataire ${i + 1}' : 'Destinataire';
      if (f.name.text.trim().isEmpty) return '$who : indiquez le nom';
      if (!phoneOk.hasMatch(f.phone.text.trim())) {
        return '$who : téléphone invalide (10 chiffres)';
      }
      if (_codEnabled &&
          f.codOn &&
          (int.tryParse(f.cod.text.replaceAll(' ', '')) ?? 0) <= 0) {
        return '$who : montant à encaisser';
      }
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

  // ---------- Interface ----------

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = _stops.length;
    return LargeTitlePage(
      title: n > 1 ? 'Tournée · $n arrêts' : 'Détails',
      bottomBar: GlassBottomBar(
        child: Row(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total · espèces',
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
                AnimatedSwitcher(
                  duration: Motion.fast,
                  child: _quoting
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: CupertinoActivityIndicator(),
                        )
                      : Text(
                          fcfa(_priceFor(_speed)),
                          key: ValueKey('$_vehicle$_speed${_priceFor(_speed)}'),
                          style: TextStyles.title2.copyWith(color: p.label),
                        ),
                ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                onPressed: _sending || _quoting ? null : _submit,
                child: _sending
                    ? const CupertinoActivityIndicator(color: Colors.white)
                    : const Text('Commander'),
              ),
            ),
          ],
        ),
      ),
      children: [
        // ----- Engin (modifiable) -----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${km(_quote['distanceKm'])} · ~${_quote['durationMin']} min${n > 1 ? ' · ordre de passage optimisé' : ''}',
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          child: Row(
            children: [
              for (final o in _offers) ...[
                if (o != _offers.first) const SizedBox(width: 8),
                Expanded(child: _vehicleChip(o, p)),
              ],
            ],
          ),
        ),
        // ----- Délai : une ligne par délai (nom | prix) -----
        InsetGroup(
          header: 'Délai',
          children: [
            for (final s in ['EXPRESS', 'STANDARD', 'SCHEDULED'])
              Pressable(
                pressedScale: 0.99,
                onTap: () {
                  hapticTap();
                  setState(() => _speed = s);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      _radio(_speed == s, p),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _speeds[s]['label'],
                          style: TextStyles.body.copyWith(
                            color: p.label,
                            fontWeight: _speed == s
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      Text(
                        fcfa(_priceFor(s)),
                        style: TextStyles.body.copyWith(
                          color: _speed == s ? p.label : p.secondaryLabel,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        // ----- Départ -----
        InsetGroup(
          header: 'Départ',
          children: [
            GroupRow(
              leading: _dot('A', ink),
              title: _pickup.label,
              subtitle: 'Modifier l’adresse',
              chevron: true,
              onTap: _changePickup,
            ),
            _PhotoRow(
              url: _pickupPhoto,
              onChanged: (u) => setState(() => _pickupPhoto = u),
            ),
          ],
        ),
        // ----- Destinataires -----
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 6, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  n > 1 ? 'DESTINATAIRES' : 'DESTINATAIRE',
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ),
              if (n < _maxStops)
                Pressable(
                  onTap: _quoting ? null : _addStop,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: ShapeDecoration(
                      color: p.accentSoft,
                      shape: const StadiumBorder(),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          PhosphorIcons.plus(PhosphorIconsStyle.bold),
                          size: 14,
                          color: accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Arrêt',
                          style: TextStyles.subheadline.copyWith(
                            color: accent,
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
        for (var i = 0; i < n; i++) _stopSection(i, p),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _vehicleChip(Map<String, dynamic> o, Palette p) {
    final v = o['vehicle'] as String;
    final on = v == _vehicle;
    return Pressable(
      onTap: () {
        hapticTap();
        setState(() => _vehicle = v);
        widget.onVehicleChanged?.call(v);
      },
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: ShapeDecoration(
          color: on ? p.card : p.fill,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: on ? accent : Colors.transparent,
              width: 1.6,
            ),
          ),
        ),
        child: Column(
          children: [
            Icon(
              vehicleIcons[v],
              size: 24,
              color: on ? accent : p.secondaryLabel,
            ),
            const SizedBox(height: 4),
            Text(
              vehicleLabels[v] ?? o['label'],
              style: TextStyles.subheadline.copyWith(
                color: p.label,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            Text(
              fcfa(_priceFor(_speed, o)),
              style: TextStyles.caption.copyWith(color: p.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _radio(bool on, Palette p) => AnimatedContainer(
    duration: Motion.fast,
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: on ? accent : p.tertiaryLabel,
        width: on ? 7 : 1.6,
      ),
    ),
  );

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
    final d = _stops[i];
    final f = _formOf(d);
    return InsetGroup(
      key: ObjectKey(d),
      children: [
        GroupRow(
          leading: _dot('${i + 1}', accent),
          title: d.place.label,
          subtitle: 'Modifier l’adresse',
          chevron: _stops.length == 1,
          onTap: () => _changeStop(d),
          trailing: _stops.length > 1
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  onPressed: () => _removeStop(d),
                  child: Icon(
                    PhosphorIcons.minusCircle(PhosphorIconsStyle.fill),
                    color: p.red,
                    size: 24,
                  ),
                )
              : null,
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
          controller: f.description,
          placeholder: 'Colis (facultatif)',
          icon: CupertinoIcons.cube_box,
        ),
        _PhotoRow(
          url: f.photo,
          onChanged: (u) => setState(() => f.photo = d.photo = u),
        ),
        if (_codEnabled) ...[
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
        ],
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
      titleColor: accent,
      trailing: _uploading ? const CupertinoActivityIndicator() : null,
      onTap: _uploading ? null : _pick,
    );
  }
}
