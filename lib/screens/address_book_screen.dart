import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../labels.dart';
import '../main.dart';
import 'widgets.dart';

/// Carnet d'adresses : destinataires mémorisés automatiquement à chaque commande
class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key});
  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Api.instance.addresses();
      if (mounted) setState(() => _items = list.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    setState(() => _items!.remove(a));
    try {
      await Api.instance.deleteAddress(a['id']);
    } catch (e) {
      if (mounted) showError(context, e);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LargeTitlePage(
      title: 'Carnet d’adresses',
      onRefresh: _load,
      children: [
        if (_items == null)
          const Padding(
            padding: EdgeInsets.all(40),
            child: CupertinoActivityIndicator(),
          ),
        if (_items != null && _items!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Vos destinataires seront ajoutés ici automatiquement après chaque commande.',
              textAlign: TextAlign.center,
              style: TextStyles.body.copyWith(color: p.secondaryLabel),
            ),
          ),
        if (_items != null && _items!.isNotEmpty)
          InsetGroup(
            footer: 'Balayez vers la gauche pour supprimer.',
            children: [
              for (final a in _items!)
                Dismissible(
                  key: ValueKey(a['id']),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: p.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(
                      PhosphorIconsBold.trash,
                      color: Colors.white,
                    ),
                  ),
                  onDismissed: (_) => _delete(a),
                  child: GroupRow(
                    leading: Avatar(a['recipientName'] ?? '?', radius: 18),
                    title: a['recipientName'],
                    subtitle:
                        '${a['address']}\n${formatPhone(a['recipientPhone'])}',
                    value: (a['usedCount'] ?? 0) > 1
                        ? '×${a['usedCount']}'
                        : null,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
