import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../countries.dart';
import '../labels.dart';
import '../main.dart';
import '../models.dart';
import 'company_picker.dart';
import 'map_picker.dart';
import 'place_search.dart';
import 'widgets.dart';

/// Détails de la commande, réduits à l'essentiel : engin, délai, départ (et numéro appelé par
/// le livreur), destinataires. Adresses modifiables (recherche ou carte), prix recalculé, arrêts.
class OrderScreen extends StatefulWidget {
  final Place pickup;
  final List<StopDraft>
  stops; // liste partagée avec l'accueil (modifiée sur place)
  final Map<String, dynamic> quote;
  final String vehicle;
  final ValueChanged<Place>? onPickupChanged;
  final ValueChanged<String>? onVehicleChanged;

  /// Entreprise choisie (sa grille, ses livreurs) ; null = toutes
  final ChosenCompany? company;
  const OrderScreen({
    this.company,
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
  final PhoneController phone;
  final cod = TextEditingController();
  bool codOn = false;

  _StopForm(StopDraft draft) : phone = PhoneController(draft.phone) {
    name.text = draft.name;
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

  /// Boutique : qui paie la livraison (elle au départ, ou le destinataire à la remise)
  String _feePaidBy = 'SENDER';
  bool get _isShop => api.user?['accountType'] == 'SHOP';
  bool _quoting = false;

  /// Numéro que le livreur appellera au départ (celui du profil par défaut)
  late final _pickupPhone = PhoneController(api.user?['phone']);

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

  /// Livreurs indépendants : pas de paiement à la livraison
  bool get _independent => widget.company.isIndependent;
  bool get _codEnabled => _quote['codEnabled'] == true && !_independent;
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
      ], companyId: widget.company?.id);
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

  /// Recherche d'une adresse, ou choix sur la carte. Renvoie un [Place] ou un [StopDraft] (carnet).
  Future<Object?> _pickAddress(
    String title,
    LatLng around, {
    bool dropoff = false,
  }) async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: title,
          near: _pickup.point,
          dropoff: dropoff,
        ),
      ),
    );
    if (res != chooseOnMap || !mounted) return res;
    return Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MapPickerScreen(title: title, initial: around, dropoff: dropoff),
      ),
    );
  }

  Future<void> _changePickup() async {
    final res = await _pickAddress('Départ', _pickup.point);
    if (res is! Place || !mounted) return;
    setState(() => _pickup = res);
    widget.onPickupChanged?.call(res);
    _requote();
  }

  Future<void> _changeStop(StopDraft d) async {
    final res = await _pickAddress(
      'Adresse de livraison',
      d.place.point,
      dropoff: true,
    );
    if (!mounted) return;
    if (res is Place) {
      d.place = res;
    } else if (res is StopDraft) {
      // Destinataire du carnet : adresse et coordonnées
      d.place = res.place;
      final f = _formOf(d);
      if (f.name.text.trim().isEmpty) f.name.text = res.name;
      if (f.phone.isBlank) f.phone.setPhone(res.phone);
      d.details = res.details;
    } else {
      return;
    }
    _requote();
  }

  Future<void> _addStop() async {
    final around = _stops.isEmpty ? _pickup.point : _stops.last.place.point;
    final res = await _pickAddress('Nouvel arrêt', around, dropoff: true);
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
    )) {
      return;
    }
    setState(() {
      _stops.remove(d);
      _forms.remove(d);
    });
    _requote();
  }

  /// Répertoire du téléphone : numéro et nom du destinataire
  Future<void> _pickContact(_StopForm f) async {
    try {
      final c = await FlutterNativeContactPicker().selectPhoneNumber();
      if (c == null || !mounted) return;
      final raw =
          c.selectedPhoneNumber ??
          (c.phoneNumbers?.isNotEmpty == true ? c.phoneNumbers!.first : '');
      final phone = parseAnyPhone(raw);
      setState(() {
        if (phone != null) {
          f.phone.setPhone(phone);
        } else if (raw.trim().isNotEmpty) {
          f.phone.text = raw.replaceAll(RegExp(r'[^\d+]'), '');
        }
        if ((c.fullName ?? '').trim().isNotEmpty) {
          f.name.text = c.fullName!.trim();
        }
      });
      if (phone == null && raw.trim().isNotEmpty) {
        showError(
          context,
          'Vérifiez ce numéro : son pays n’est pas encore desservi',
        );
      }
    } catch (e) {
      if (mounted) {
        showError(context, 'Contacts inaccessibles : saisissez le numéro');
      }
    }
  }

  // ---------- Commande ----------

  Future<void> _submit() async {
    final missing = _missing();
    if (missing != null) {
      showError(context, missing);
      return;
    }
    // Le client accepte en connaissance de cause un livreur indépendant
    if (_independent &&
        !await confirm(
          context,
          'Commander un livreur indépendant ?',
          message: IndependentNotice.text,
          ok: 'Oui, commander',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _sending = true);
    String? optStr(String? s) => (s ?? '').trim().isEmpty ? null : s!.trim();
    try {
      final d = await api.createDelivery({
        'vehicleType': _vehicle,
        'speed': _speed,
        if (_independent)
          'forIndependents': true
        else
          'companyId': ?widget.company?.id,
        'pickupLat': _pickup.point.latitude,
        'pickupLng': _pickup.point.longitude,
        'pickupAddress': _pickup.label,
        'pickupContactName': ?optStr(api.user?['name']),
        'pickupPhone': _pickupPhone.e164,
        if (_isShop) 'feePaidBy': _feePaidBy,
        'stops': [
          for (final s in _stops)
            {
              'lat': s.place.point.latitude,
              'lng': s.place.point.longitude,
              'address': s.place.label,
              'recipientName': _formOf(s).name.text.trim(),
              'recipientPhone': _formOf(s).phone.e164,
              'details': ?optStr(s.details),
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
    final pickupError = _pickupPhone.validate();
    if (pickupError != null) return 'Départ : $pickupError';
    for (var i = 0; i < _stops.length; i++) {
      final f = _formOf(_stops[i]);
      final who = _stops.length > 1 ? 'Destinataire ${i + 1}' : 'Destinataire';
      if (f.name.text.trim().isEmpty) return '$who : indiquez le nom';
      final phoneError = f.phone.validate();
      if (phoneError != null) return '$who : $phoneError';
      if (_codEnabled &&
          f.codOn &&
          (int.tryParse(f.cod.text.replaceAll(' ', '')) ?? 0) <= 0) {
        return '$who : montant à encaisser';
      }
    }
    return null;
  }

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
      inline: true,
      trailing: n < _maxStops
          ? Pressable(
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
                    Icon(PhosphorIconsBold.plus, size: 14, color: accent),
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
            )
          : null,
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
                if (priceFactors(_quote).isNotEmpty)
                  Text(
                    priceFactors(_quote),
                    style: TextStyles.caption.copyWith(color: p.secondaryLabel),
                  ),
                AnimatedSwitcher(
                  duration: Motion.fast,
                  child: _quoting
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: CupertinoActivityIndicator(),
                        )
                      : Text(
                          formatMoney(_priceFor(_speed)),
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
        if (_independent) const IndependentNotice(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            [
              '${km(_quote['distanceKm'])} · ~${_quote['durationMin']} min',
              if (n > 1) 'ordre de passage optimisé',
              _independent
                  ? 'livreur indépendant'
                  : 'livré par ${widget.company?.name ?? 'toutes les entreprises'}',
            ].join(' · '),
            style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
          ),
        ),
        // ----- Engin : une ligne, une colonne par engin -----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
          child: Row(
            children: [
              for (final o in _offers) ...[
                if (o != _offers.first) const SizedBox(width: 8),
                Expanded(child: _vehicleChip(o, p)),
              ],
            ],
          ),
        ),
        // ----- Délai : une ligne, une colonne par délai -----
        _sectionTitle('Délai', p),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
          child: Row(
            children: [
              for (final s in ['EXPRESS', 'STANDARD', 'SCHEDULED']) ...[
                if (s != 'EXPRESS') const SizedBox(width: 8),
                Expanded(child: _speedChip(s, p)),
              ],
            ],
          ),
        ),
        // ----- Départ -----
        InsetGroup(
          header: 'Départ',
          footer:
              'Le livreur vous appellera sur ce numéro pour récupérer le colis.',
          children: [
            GroupRow(
              leading: _dot('A', ink),
              title: _pickup.label,
              subtitle: 'Modifier l’adresse',
              chevron: true,
              onTap: _changePickup,
            ),
            PhoneField(controller: _pickupPhone),
          ],
        ),
        if (_isShop)
          InsetGroup(
            header: 'Qui paie la livraison ?',
            footer: _feePaidBy == 'RECIPIENT'
                ? (n > 1
                      ? 'Chaque destinataire paie sa part du prix au livreur, en espèces, à la remise. S’il n’est pas livré, la part vous revient au retour du colis.'
                      : 'Le destinataire paie le prix de la livraison au livreur, en espèces, à la remise. S’il n’est pas livré, vous la payez au retour du colis.')
                : 'Vous payez la livraison au livreur, en espèces, quand il récupère les colis.',
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: CupertinoSlidingSegmentedControl<String>(
                  groupValue: _feePaidBy,
                  onValueChanged: (v) {
                    if (v != null) setState(() => _feePaidBy = v);
                  },
                  children: const {
                    'SENDER': Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Ma boutique'),
                    ),
                    'RECIPIENT': Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Le destinataire'),
                    ),
                  },
                ),
              ),
            ],
          ),
        // ----- Destinataires -----
        for (var i = 0; i < n; i++) _stopSection(i, p),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _sectionTitle(String label, Palette p) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 0, 16, 8),
    child: Text(
      label.toUpperCase(),
      style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
    ),
  );

  /// Case sélectionnable (engin ou délai)
  Widget _choice({
    required bool on,
    required VoidCallback onTap,
    required Palette p,
    required List<Widget> children,
  }) => Pressable(
    onTap: () {
      hapticTap();
      onTap();
    },
    child: AnimatedContainer(
      duration: Motion.medium,
      curve: Motion.curve,
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
      decoration: ShapeDecoration(
        color: on ? p.card : p.fill,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: on ? accent : Colors.transparent, width: 1.6),
        ),
      ),
      child: Column(children: children),
    ),
  );

  Widget _vehicleChip(Map<String, dynamic> o, Palette p) {
    final v = o['vehicle'] as String;
    final on = v == _vehicle;
    return _choice(
      on: on,
      p: p,
      onTap: () {
        setState(() => _vehicle = v);
        widget.onVehicleChanged?.call(v);
      },
      children: [
        Icon(vehicleIcons[v], size: 24, color: on ? accent : p.secondaryLabel),
        const SizedBox(height: 4),
        Text(
          vehicleLabels[v] ?? o['label'],
          style: TextStyles.subheadline.copyWith(
            color: p.label,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        Text(
          formatMoney(_priceFor(_speed, o)),
          style: TextStyles.caption.copyWith(color: p.secondaryLabel),
        ),
      ],
    );
  }

  Widget _speedChip(String s, Palette p) {
    final on = s == _speed;
    return _choice(
      on: on,
      p: p,
      onTap: () => setState(() => _speed = s),
      children: [
        Text(
          _speeds[s]['label'],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyles.subheadline.copyWith(
            color: p.label,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          formatMoney(_priceFor(s)),
          style: TextStyles.headline.copyWith(
            color: on ? accent : p.secondaryLabel,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
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
    final d = _stops[i];
    final f = _formOf(d);
    return InsetGroup(
      key: ObjectKey(d),
      header: _stops.length > 1 ? 'Destinataire ${i + 1}' : 'Destinataire',
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
                    PhosphorIconsFill.minusCircle,
                    color: p.red,
                    size: 24,
                  ),
                )
              : null,
        ),
        GroupField(
          controller: f.name,
          placeholder: 'Nom du destinataire',
          icon: PhosphorIconsBold.user,
        ),
        PhoneField(
          controller: f.phone,
          trailing: ContactButton(onPressed: () => _pickContact(f)),
        ),
        if (_codEnabled) ...[
          GroupSwitch(
            title: 'Paiement à la livraison',
            subtitle:
                'Le livreur encaisse la marchandise · +${formatMoney(_codFee)}',
            value: f.codOn,
            onChanged: (v) => setState(() => f.codOn = v),
          ),
          if (f.codOn)
            GroupField(
              controller: f.cod,
              placeholder: 'Montant à encaisser',
              icon: PhosphorIconsBold.creditCard,
              keyboardType: TextInputType.number,
              validator: _amount,
            ),
        ],
      ],
    );
  }
}
