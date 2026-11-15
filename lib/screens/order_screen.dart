import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';
import 'widgets.dart';

/// Détails de la commande : repères, destinataire, prix → Commander
class OrderScreen extends StatefulWidget {
  final LatLng pickup;
  final LatLng dropoff;
  const OrderScreen({super.key, required this.pickup, required this.dropoff});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();
  late String _from = nearestCommune(widget.pickup);
  late String _to = nearestCommune(widget.dropoff);
  int? _price;
  bool _sending = false;

  final _pickupAddress = TextEditingController();
  late final _pickupPhone = TextEditingController(text: api.user?['phone']);
  final _dropoffAddress = TextEditingController();
  final _recipientName = TextEditingController();
  final _recipientPhone = TextEditingController();
  final _description = TextEditingController();

  @override
  void initState() {
    super.initState();
    _quote();
  }

  Future<void> _quote() async {
    try {
      final price = await api.quote(_from, _to);
      if (mounted) setState(() => _price = price);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _sending = true);
    try {
      final d = await api.createDelivery({
        'pickupCommune': _from,
        'pickupAddress': _pickupAddress.text.trim(),
        'pickupPhone': _pickupPhone.text.trim(),
        'pickupLat': widget.pickup.latitude,
        'pickupLng': widget.pickup.longitude,
        'dropoffCommune': _to,
        'dropoffAddress': _dropoffAddress.text.trim(),
        'dropoffLat': widget.dropoff.latitude,
        'dropoffLng': widget.dropoff.longitude,
        'recipientName': _recipientName.text.trim(),
        'recipientPhone': _recipientPhone.text.trim(),
        'packageDescription': _description.text.trim(),
      });
      if (mounted) Navigator.pop(context, d);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatoire' : null;
  String? _phone(String? v) =>
      RegExp(r'^0\d{9}$').hasMatch(v?.trim() ?? '') ? null : '10 chiffres, ex : 0701020304';

  Widget _communePicker(String value, bool dropoff, ValueChanged<String> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        prefixIcon: Icon(dropoff ? Icons.square : Icons.circle, size: 14, color: dropoff ? letaOrange : letaGreen),
      ),
      items: communeCenters.keys.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
        _quote();
      },
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon,
          {String? Function(String?)? validator, bool phone = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextFormField(
          controller: c,
          keyboardType: phone ? TextInputType.phone : TextInputType.text,
          decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon)),
          validator: validator,
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Détails de la livraison')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            _section('Départ'),
            _communePicker(_from, false, (v) => _from = v),
            _field(_pickupAddress, 'Repère (ex : Angré 8e tranche, près de la pharmacie)', Icons.signpost_outlined,
                validator: _required),
            _field(_pickupPhone, 'Téléphone au départ', Icons.phone_outlined, validator: _phone, phone: true),
            _section('Arrivée'),
            _communePicker(_to, true, (v) => _to = v),
            _field(_dropoffAddress, 'Repère à l’arrivée', Icons.signpost_outlined, validator: _required),
            _field(_recipientName, 'Nom du destinataire', Icons.person_outline, validator: _required),
            _field(_recipientPhone, 'Téléphone du destinataire', Icons.phone_outlined,
                validator: _phone, phone: true),
            _section('Colis'),
            _field(_description, 'Que livre-t-on ? (facultatif)', Icons.inventory_2_outlined),
          ],
        ),
      ),
      bottomNavigationBar: BottomPanel(children: [
        // Offre (une seule pour le MVP)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: letaOrange, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            const Icon(Icons.two_wheeler, size: 36, color: letaOrange),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Moto Express', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text('Petits colis · Espèces', style: TextStyle(color: Colors.grey)),
              ]),
            ),
            Text(_price == null ? '…' : fcfa(_price!),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ]),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _sending || _price == null ? null : _submit,
          child: Text(_sending ? 'Envoi…' : 'Commander'),
        ),
      ]),
    );
  }
}
