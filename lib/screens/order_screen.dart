import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import 'widgets.dart';

/// Options et informations de la commande : délai, paiement à la livraison, adresses, contacts.
class OrderScreen extends StatefulWidget {
  final Place pickup;
  final Place dropoff;
  final Map<String, dynamic> quote;
  final String vehicle;
  const OrderScreen({
    super.key,
    required this.pickup,
    required this.dropoff,
    required this.quote,
    required this.vehicle,
  });

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();

  String _speed = 'STANDARD';
  bool _cod = false;
  bool _sending = false;
  String? _pickupPhoto;
  String? _dropoffPhoto;

  final _codAmount = TextEditingController();
  final _pickupDetails = TextEditingController();
  late final _senderName = TextEditingController(text: api.user?['name']);
  late final _pickupPhone = TextEditingController(text: api.user?['phone']);
  final _dropoffDetails = TextEditingController();
  final _recipientName = TextEditingController();
  final _recipientPhone = TextEditingController();
  final _description = TextEditingController();
  final _comment = TextEditingController();

  Map<String, dynamic> get _offer => (widget.quote['offers'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((o) => o['vehicle'] == widget.vehicle);
  Map<String, dynamic> get _speeds =>
      widget.quote['speeds'] as Map<String, dynamic>;
  int get _codFee => widget.quote['codFee'] as int;
  int _priceFor(String speed) =>
      (_offer['prices'][speed] as int) + (_cod ? _codFee : 0);

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _sending = true);
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final d = await api.createDelivery(
        {
          'vehicleType': widget.vehicle,
          'speed': _speed,
          'pickupLat': widget.pickup.point.latitude,
          'pickupLng': widget.pickup.point.longitude,
          'pickupAddress': widget.pickup.label,
          'pickupDetails': opt(_pickupDetails),
          'pickupContactName': opt(_senderName),
          'pickupPhone': _pickupPhone.text.trim(),
          'pickupPhotoUrl': _pickupPhoto,
          'dropoffLat': widget.dropoff.point.latitude,
          'dropoffLng': widget.dropoff.point.longitude,
          'dropoffAddress': widget.dropoff.label,
          'dropoffDetails': opt(_dropoffDetails),
          'recipientName': _recipientName.text.trim(),
          'recipientPhone': _recipientPhone.text.trim(),
          'dropoffPhotoUrl': _dropoffPhoto,
          'packageDescription': opt(_description),
          'courierComment': opt(_comment),
          'codAmount': _cod
              ? int.parse(_codAmount.text.replaceAll(' ', ''))
              : 0,
        }..removeWhere((_, v) => v == null),
      );
      if (mounted) Navigator.pop(context, d);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF3F4F6),
        title: Row(
          children: [
            Icon(vehicleIcons[widget.vehicle], color: letoOrange),
            const SizedBox(width: 8),
            Text(_offer['label']),
          ],
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: [
            // ----- Délai -----
            _Section(
              title: 'Délai de livraison',
              children: [
                for (final s in ['EXPRESS', 'STANDARD', 'SCHEDULED'])
                  _SpeedTile(
                    label: _speeds[s]['label'],
                    description: _speeds[s]['description'],
                    price: _priceFor(s),
                    selected: _speed == s,
                    onTap: () => setState(() => _speed = s),
                  ),
              ],
            ),
            // ----- Paiement à la livraison -----
            _Section(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _cod,
                  onChanged: (v) => setState(() => _cod = v),
                  secondary: const Icon(
                    Icons.account_balance_wallet_outlined,
                    color: letoDark,
                  ),
                  title: const Text(
                    'Paiement à la livraison',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Le livreur encaisse le prix de la marchandise auprès du destinataire. '
                    'L’entreprise de livraison vous le reverse. Frais : ${fcfa(_codFee)}',
                  ),
                ),
                if (_cod)
                  TextFormField(
                    controller: _codAmount,
                    keyboardType: TextInputType.number,
                    validator: _amount,
                    decoration: const InputDecoration(
                      hintText: 'Montant à encaisser (FCFA)',
                      prefixIcon: Icon(Icons.payments_outlined),
                    ),
                  ),
              ],
            ),
            // ----- Départ -----
            _Section(
              children: [
                PointLine(
                  title: widget.pickup.label,
                  detail: widget.pickup.sublabel,
                ),
                _field(
                  _pickupDetails,
                  'Repère, étage, portail…',
                  Icons.signpost_outlined,
                ),
                _PhotoField(
                  url: _pickupPhoto,
                  onChanged: (u) => setState(() => _pickupPhoto = u),
                ),
                _field(
                  _senderName,
                  'Expéditeur',
                  Icons.person_outline,
                  validator: _required,
                ),
                _field(
                  _pickupPhone,
                  'Téléphone de l’expéditeur',
                  Icons.phone_outlined,
                  validator: _phone,
                  phone: true,
                ),
              ],
            ),
            // ----- Arrivée -----
            _Section(
              children: [
                PointLine(
                  dropoff: true,
                  title: widget.dropoff.label,
                  detail: widget.dropoff.sublabel,
                ),
                _field(
                  _dropoffDetails,
                  'Repère, étage, portail…',
                  Icons.signpost_outlined,
                ),
                _PhotoField(
                  url: _dropoffPhoto,
                  onChanged: (u) => setState(() => _dropoffPhoto = u),
                ),
                _field(
                  _recipientName,
                  'Nom du destinataire',
                  Icons.person_outline,
                  validator: _required,
                ),
                _field(
                  _recipientPhone,
                  'Téléphone du destinataire',
                  Icons.phone_outlined,
                  validator: _phone,
                  phone: true,
                ),
              ],
            ),
            // ----- Colis -----
            _Section(
              children: [
                _field(
                  _description,
                  'Que livre-t-on ? (facultatif)',
                  Icons.inventory_2_outlined,
                ),
                _field(
                  _comment,
                  'Commentaire pour le coursier (facultatif)',
                  Icons.chat_bubble_outline,
                ),
              ],
            ),
            // ----- Paiement -----
            const _Section(
              children: [
                Row(
                  children: [
                    Icon(Icons.payments_outlined, color: letoGreen),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Paiement de la course en espèces, au livreur',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Commander'),
                      Text(
                        fcfa(_priceFor(_speed)),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String hint,
    IconData icon, {
    String? Function(String?)? validator,
    bool phone = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: TextFormField(
      controller: c,
      keyboardType: phone ? TextInputType.phone : TextInputType.text,
      decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon)),
      validator: validator,
    ),
  );
}

class _Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _Section({this.title, required this.children});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
        ],
        ...children,
      ],
    ),
  );
}

class _SpeedTile extends StatelessWidget {
  final String label;
  final String description;
  final int price;
  final bool selected;
  final VoidCallback onTap;
  const _SpeedTile({
    required this.label,
    required this.description,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            fcfa(price),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            color: selected ? letoOrange : Colors.black26,
            size: 28,
          ),
        ],
      ),
    ),
  );
}

/// Photo d'adresse : prise ou choisie, envoyée à l'API
class _PhotoField extends StatefulWidget {
  final String? url;
  final ValueChanged<String?> onChanged;
  const _PhotoField({required this.url, required this.onChanged});

  @override
  State<_PhotoField> createState() => _PhotoFieldState();
}

class _PhotoFieldState extends State<_PhotoField> {
  bool _uploading = false;

  Future<void> _pick() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
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
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: widget.url == null
          ? OutlinedButton.icon(
              onPressed: _uploading ? null : _pick,
              icon: _uploading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_a_photo_outlined),
              label: const Text('Photo de l’adresse (portail, devanture…)'),
            )
          : Row(
              children: [
                AddressPhoto(widget.url!),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () => widget.onChanged(null),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Retirer'),
                ),
              ],
            ),
    );
  }
}
