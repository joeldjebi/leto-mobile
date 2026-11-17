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
import 'place_search.dart';
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
  LatLng? _here;

  /// Réorganisation en cours : ordre de travail (ids)
  List<String>? _draft;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    myPosition().then((p) {
      if (mounted && p != null) setState(() => _here = p);
    });
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
    final r = await Navigator.of(context).push<Object>(
      CupertinoPageRoute(builder: (_) => const LogbookEntryScreen()),
    );
    if (r == null || !mounted) return;
    final list = r is List
        ? r.cast<Map<String, dynamic>>()
        : [r as Map<String, dynamic>];
    for (final e in list.reversed) {
      _replace(e);
    }
    hapticSuccess();
    showInfo(
      context,
      list.length > 1
          ? '${list.length} livraisons enregistrées dans votre carnet'
          : 'Livraison enregistrée dans votre carnet',
    );
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

  static LatLng? _pt(Map<String, dynamic> e) =>
      e['lat'] == null || e['lng'] == null
      ? null
      : LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble());

  /// Ordre choisi par le livreur ?
  bool _manual(List<Map<String, dynamic>> todo) =>
      todo.any((e) => e['sortOrder'] != null);

  /// Livraisons à faire : dans l'ordre du livreur s'il en a choisi un,
  /// sinon la plus proche d'abord (de proche en proche depuis sa position).
  List<Map<String, dynamic>> _ordered(List<Map<String, dynamic>> todo) {
    int byDate(Map a, Map b) =>
        (a['createdAt'] as String).compareTo(b['createdAt'] as String);
    if (_manual(todo)) {
      return [...todo]..sort((a, b) {
        final x = (a['sortOrder'] as int?) ?? 1 << 30;
        final y = (b['sortOrder'] as int?) ?? 1 << 30;
        return x != y ? x.compareTo(y) : byDate(a, b);
      });
    }
    final left = todo.where((e) => _pt(e) != null).toList()..sort(byDate);
    final out = <Map<String, dynamic>>[];
    var cur = _here;
    while (left.isNotEmpty) {
      var best = 0;
      if (cur != null) {
        for (var i = 1; i < left.length; i++) {
          if (distanceKm(cur, _pt(left[i])!) <
              distanceKm(cur, _pt(left[best])!))
            best = i;
        }
      }
      final e = left.removeAt(best);
      out.add(e);
      cur = _pt(e);
    }
    return out
      ..addAll(todo.where((e) => _pt(e) == null).toList()..sort(byDate));
  }

  Future<void> _saveOrder(List<String> ids) async {
    try {
      await api.setLogbookOrder(ids);
      if (!mounted) return;
      setState(() {
        _draft = null;
        _entries = [
          for (final e in _entries ?? <Map<String, dynamic>>[])
            {
              ...e,
              'sortOrder': ids.contains(e['id']) ? ids.indexOf(e['id']) : null,
            },
        ];
      });
      hapticSuccess();
      showInfo(
        context,
        ids.isEmpty
            ? 'Tri : la plus proche d’abord'
            : 'Ordre de passage enregistré',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _move(int i, int delta) {
    final d = [...?_draft];
    final j = i + delta;
    if (j < 0 || j >= d.length) return;
    hapticTap();
    final x = d.removeAt(i);
    d.insert(j, x);
    setState(() => _draft = d);
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
    final todoRaw = (list ?? []).where((e) => e['status'] == 'TODO').toList();
    final manual = _manual(todoRaw);
    var todo = _ordered(todoRaw);
    final draft = _draft;
    if (draft != null) {
      final byId = {for (final e in todo) e['id']: e};
      todo = [for (final id in draft) ?byId[id]];
    }
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
          if (todo.isNotEmpty) ...[
            _orderBar(p, todo, manual),
            InsetGroup(
              header:
                  'À livrer (${todo.length}) · ${manual || draft != null ? 'votre ordre' : 'la plus proche d’abord'}',
              children: [
                for (final (i, e) in todo.indexed)
                  draft != null
                      ? _reorderTile(p, e, i, todo.length)
                      : _tile(p, e, rank: i + 1),
              ],
            ),
          ],
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

  Widget _orderBar(Palette p, List<Map<String, dynamic>> todo, bool manual) {
    final editing = _draft != null;
    Widget btn(String t, VoidCallback onTap, {bool bold = false}) => TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(
        t,
        style: TextStyles.subheadline.copyWith(
          color: accent,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
    if (todo.length < 2 && !manual) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        children: editing
            ? [
                btn('Annuler', () => setState(() => _draft = null)),
                btn('Terminé', () => _saveOrder(_draft!), bold: true),
              ]
            : [
                if (manual) btn('La plus proche d’abord', () => _saveOrder([])),
                if (todo.length > 1)
                  btn('Réorganiser', () {
                    hapticTap();
                    setState(
                      () => _draft = [for (final e in todo) e['id'] as String],
                    );
                  }),
              ],
      ),
    );
  }

  String? _distance(Map<String, dynamic> e) {
    final pt = _pt(e);
    if (_here == null || pt == null) return null;
    final km = distanceKm(_here!, pt);
    return km < 1
        ? '${(km * 1000).round()} m'
        : '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
  }

  Widget _reorderTile(Palette p, Map<String, dynamic> e, int i, int n) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Text(
              '${i + 1}',
              style: TextStyles.headline.copyWith(color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                e['address'],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyles.body.copyWith(color: p.label),
              ),
            ),
            IconButton(
              onPressed: i == 0 ? null : () => _move(i, -1),
              tooltip: 'Monter',
              icon: const Icon(CupertinoIcons.arrow_up, size: 20),
              color: accent,
            ),
            IconButton(
              onPressed: i == n - 1 ? null : () => _move(i, 1),
              tooltip: 'Descendre',
              icon: const Icon(CupertinoIcons.arrow_down, size: 20),
              color: accent,
            ),
          ],
        ),
      );

  Widget _tile(Palette p, Map<String, dynamic> e, {int? rank}) {
    final (label, color) = logbookStatus(e['status'], p);
    final at = DateTime.parse(e['createdAt']).toLocal();
    final dist = rank == null ? null : _distance(e);
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
                    [
                      if (rank != null) 'n°$rank',
                      ?dist,
                      e['recipientName'] ?? 'Sans nom',
                      e['recipientPhone'],
                      if (rank == null) _hm(at),
                    ].join(' · '),
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

/// Un destinataire en cours de saisie
class _Recipient {
  final address = TextEditingController();
  final phone = TextEditingController();
  final name = TextEditingController();
  final price = TextEditingController();

  /// Position de l'adresse et libellé correspondant (si l'adresse vient du GPS ou de la recherche)
  LatLng? point;
  String? pointLabel;
  bool locating = false;

  _Recipient();
  _Recipient.of(Map<String, dynamic> e) {
    address.text = e['address'] ?? '';
    phone.text = e['recipientPhone'] ?? '';
    name.text = e['recipientName'] ?? '';
    price.text = e['price']?.toString() ?? '';
    if (e['lat'] != null && e['lng'] != null) {
      point = LatLng(
        (e['lat'] as num).toDouble(),
        (e['lng'] as num).toDouble(),
      );
      pointLabel = address.text;
    }
  }

  void dispose() {
    address.dispose();
    phone.dispose();
    name.dispose();
    price.dispose();
  }
}

/// Saisie (ou modification) de livraisons du carnet : une photo du colis,
/// un ou plusieurs destinataires (adresse, numéro, prix).
/// La photo se prend avec l'appareil photo uniquement (pas de photothèque).
class LogbookEntryScreen extends StatefulWidget {
  final Map<String, dynamic>? entry;
  const LogbookEntryScreen({super.key, this.entry});
  @override
  State<LogbookEntryScreen> createState() => _LogbookEntryScreenState();
}

class _LogbookEntryScreenState extends State<LogbookEntryScreen> {
  final api = Api.instance;
  final _form = GlobalKey<FormState>();
  late final List<_Recipient> _recipients = [
    widget.entry == null ? _Recipient() : _Recipient.of(widget.entry!),
  ];
  late final _note = TextEditingController(text: widget.entry?['note']);
  late String? _photo = widget.entry?['photoUrl'];
  File? _localPhoto;
  bool _uploading = false;
  bool _saving = false;
  LatLng? _here;

  bool get _editing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    // Par défaut : l'adresse du premier destinataire = position actuelle du livreur
    if (!_editing) _locate(_recipients.first, quiet: true);
  }

  @override
  void dispose() {
    for (final r in _recipients) {
      r.dispose();
    }
    _note.dispose();
    super.dispose();
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

  /// Remplit l'adresse avec la position actuelle
  Future<void> _locate(_Recipient r, {bool quiet = false}) async {
    setState(() => r.locating = true);
    try {
      final p = await myPosition();
      if (p == null) {
        if (quiet) return;
        throw ApiException('Position indisponible : activez la localisation');
      }
      _here = p;
      final place = await api.reverse(p);
      if (!mounted) return;
      // Sans écraser ce que le livreur a déjà tapé (remplissage automatique)
      if (quiet && r.address.text.trim().isNotEmpty) return;
      final label = [
        place.label,
        place.sublabel,
      ].where((s) => s.isNotEmpty).join(', ');
      r.address.text = label;
      r.point = p;
      r.pointLabel = label;
    } catch (e) {
      if (mounted && !quiet) showError(context, e);
    } finally {
      if (mounted) setState(() => r.locating = false);
    }
  }

  /// Recherche d'un lieu : adresse + position (sert au tri par le plus proche)
  Future<void> _search(_Recipient r) async {
    final res = await Navigator.of(context).push<Object>(
      CupertinoPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: 'Adresse de livraison',
          near: _here,
          allowMap: false,
        ),
      ),
    );
    if (res is! Place || !mounted) return;
    final label = [
      res.label,
      res.sublabel,
    ].where((s) => s.isNotEmpty).join(', ');
    setState(() {
      r.address.text = label;
      r.point = res.point;
      r.pointLabel = label;
    });
  }

  Future<void> _pickContact(_Recipient r) async {
    try {
      final c = await FlutterNativeContactPicker().selectPhoneNumber();
      if (c == null || !mounted) return;
      final raw =
          c.selectedPhoneNumber ??
          (c.phoneNumbers?.isNotEmpty == true ? c.phoneNumbers!.first : '');
      final phone = normalizePhone(raw);
      setState(() {
        if (phone.isNotEmpty) r.phone.text = phone;
        if ((c.fullName ?? '').trim().isNotEmpty &&
            r.name.text.trim().isEmpty) {
          r.name.text = c.fullName!.trim();
        }
      });
    } catch (_) {
      if (mounted) showError(context, 'Répertoire indisponible');
    }
  }

  void _add() {
    hapticTap();
    setState(() => _recipients.add(_Recipient()));
  }

  void _remove(_Recipient r) {
    hapticTap();
    setState(() => _recipients.remove(r));
    r.dispose();
  }

  /// Position de l'adresse : celle du GPS / de la recherche si le texte n'a pas changé,
  /// sinon une recherche rapide sur le texte tapé (au mieux, pour le tri par le plus proche)
  Future<LatLng?> _pointOf(_Recipient r) async {
    final text = r.address.text.trim();
    if (r.point != null && r.pointLabel?.trim() == text) return r.point;
    try {
      final found = await api.search(text, near: _here ?? abidjan);
      if (found.isNotEmpty &&
          distanceKm(found.first.point, _here ?? abidjan) < 60) {
        return found.first.point;
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> _body(_Recipient r) async {
    final pt = await _pointOf(r);
    return {
      'address': r.address.text.trim(),
      'recipientPhone': normalizePhone(r.phone.text),
      'recipientName': r.name.text.trim(),
      'price': int.parse(r.price.text.replaceAll(RegExp(r'\D'), '')),
      if (pt != null) 'lat': pt.latitude,
      if (pt != null) 'lng': pt.longitude,
    };
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
      final note = _note.text.trim();
      final Object r;
      if (_editing) {
        r = await api.updateLogbookEntry(widget.entry!['id'], {
          ...await _body(_recipients.first),
          'note': note,
        });
      } else {
        final entries = [for (final x in _recipients) await _body(x)];
        r = await api.addLogbookEntries({
          'photoUrl': _photo,
          'note': note,
          'entries': entries,
        });
      }
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
    final n = _recipients.length;
    return LargeTitlePage(
      title: _editing ? 'Modifier la livraison' : 'Nouvelle livraison',
      inline: true,
      bottomBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _saving || _uploading ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: Text(
            _saving
                ? 'Enregistrement…'
                : n > 1
                ? 'Enregistrer $n livraisons'
                : 'Enregistrer dans le carnet',
          ),
        ),
      ),
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ----- Photo du colis (bloc compact) -----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                child: _photoRow(p),
              ),
              for (final (i, r) in _recipients.indexed)
                _recipientGroup(p, r, i, n),
              if (!_editing)
                InsetGroup(
                  children: [
                    GroupRow(
                      leading: Icon(
                        CupertinoIcons.add_circled_solid,
                        color: accent,
                        size: 22,
                      ),
                      title: 'Ajouter un destinataire',
                      titleColor: accent,
                      onTap: _recipients.length >= 20 ? null : _add,
                    ),
                  ],
                ),
              InsetGroup(
                header: 'Note',
                footer: _editing
                    ? 'Chaque modification est gardée dans l’historique, visible par votre entreprise.'
                    : n > 1
                    ? 'Une livraison par destinataire, avec la même photo et la même note. Votre entreprise les voit.'
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

  Widget _iconButton(IconData icon, String tip, VoidCallback? onTap) =>
      IconButton(
        onPressed: onTap,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 22, color: accent),
      );

  Widget _recipientGroup(Palette p, _Recipient r, int i, int n) => InsetGroup(
    header: n > 1 ? 'Destinataire ${i + 1}' : 'Destinataire',
    children: [
      GroupField(
        controller: r.address,
        placeholder: r.locating
            ? 'Localisation…'
            : 'Adresse : quartier, rue, repère…',
        icon: CupertinoIcons.location_solid,
        maxLines: 2,
        validator: (v) =>
            (v ?? '').trim().isEmpty ? 'Adresse obligatoire' : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconButton(
              CupertinoIcons.search,
              'Rechercher l’adresse',
              () => _search(r),
            ),
            r.locating
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CupertinoActivityIndicator(),
                  )
                : _iconButton(
                    CupertinoIcons.location_fill,
                    'Ma position',
                    () => _locate(r),
                  ),
          ],
        ),
      ),
      GroupField(
        controller: r.phone,
        placeholder: 'Numéro (10 chiffres)',
        icon: CupertinoIcons.phone_fill,
        keyboardType: TextInputType.phone,
        validator: (v) => RegExp(r'^0\d{9}$').hasMatch(normalizePhone(v ?? ''))
            ? null
            : 'Numéro à 10 chiffres, ex : 0701020304',
        trailing: _iconButton(
          CupertinoIcons.person_crop_circle,
          'Répertoire',
          () => _pickContact(r),
        ),
      ),
      GroupField(
        controller: r.name,
        placeholder: 'Nom (facultatif)',
        icon: CupertinoIcons.person_fill,
      ),
      GroupField(
        controller: r.price,
        placeholder: 'Prix en F CFA',
        icon: CupertinoIcons.money_dollar_circle_fill,
        keyboardType: TextInputType.number,
        validator: (v) =>
            int.tryParse((v ?? '').replaceAll(RegExp(r'\D'), '')) == null
            ? 'Prix obligatoire'
            : null,
      ),
      if (n > 1)
        GroupRow(
          leading: Icon(
            CupertinoIcons.minus_circle_fill,
            color: p.red,
            size: 20,
          ),
          title: 'Retirer ce destinataire',
          titleColor: p.red,
          onTap: () => _remove(r),
        ),
    ],
  );

  /// Photo du colis : ligne compacte (miniature + texte)
  Widget _photoRow(Palette p) {
    final has = _localPhoto != null || _photo != null;
    const size = 56.0;
    final image = _localPhoto != null
        ? Image.file(_localPhoto!, fit: BoxFit.cover, width: size, height: size)
        : _photo != null
        ? Image.network(
            photoUrl(_photo!),
            fit: BoxFit.cover,
            width: size,
            height: size,
            errorBuilder: (_, _, _) =>
                Container(width: size, height: size, color: p.fill),
          )
        : null;
    return Pressable(
      onTap: _editing || _uploading ? null : _takePhoto,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: size,
              height: size,
              child: ClipRSuperellipse(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    image ??
                        Container(
                          decoration: const BoxDecoration(
                            gradient: letoGradient,
                          ),
                          child: const Icon(
                            CupertinoIcons.camera_fill,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                    if (_uploading)
                      Container(
                        color: Colors.black38,
                        child: const Center(
                          child: CupertinoActivityIndicator(
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    has ? 'Photo du colis' : 'Prendre le colis en photo',
                    style: TextStyles.headline.copyWith(color: p.label),
                  ),
                  Text(
                    _uploading
                        ? 'Envoi…'
                        : has
                        ? 'Photo prise ✓'
                        : 'Obligatoire · appareil photo uniquement',
                    style: TextStyles.footnote.copyWith(
                      color: has ? p.green : p.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            if (has && !_editing && !_uploading)
              Text(
                'Reprendre',
                style: TextStyles.subheadline.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (!has)
              Icon(
                CupertinoIcons.chevron_right,
                size: 18,
                color: p.tertiaryLabel,
              ),
          ],
        ),
      ),
    );
  }
}
