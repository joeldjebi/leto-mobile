import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';
import '../models.dart';
import 'widgets.dart';

/// Résultat spécial : l'utilisateur veut placer le point sur la carte
const chooseOnMap = 'map';

/// Recherche d'un lieu (Google + OpenStreetMap via l'API) et, pour une livraison,
/// les destinataires du carnet d'adresses.
/// Renvoie un [Place], un [StopDraft] (carnet) ou [chooseOnMap].
class PlaceSearchScreen extends StatefulWidget {
  final String title;
  final LatLng? near;
  final bool dropoff;
  final bool
  allowMap; // « Choisir sur la carte » (absent hors de l'écran carte)
  const PlaceSearchScreen({
    super.key,
    required this.title,
    this.near,
    this.dropoff = false,
    this.allowMap = true,
  });

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  List<Map<String, dynamic>> _saved = [];
  bool _loading = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.dropoff) _loadSaved('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadSaved(String q) async {
    try {
      final list = await Api.instance.addresses(q: q);
      if (mounted) setState(() => _saved = list.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(q.trim()),
    );
  }

  Future<void> _search(String q) async {
    _query = q;
    if (widget.dropoff) _loadSaved(q);
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await Api.instance.search(q, near: widget.near);
      if (mounted && q == _query) setState(() => _results = res);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && q == _query) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = widget.dropoff ? accent : p.green;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: Text(widget.title),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.maybePop(context),
          child: const Icon(CupertinoIcons.back, color: accent, size: 28),
        ),
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: CupertinoSearchTextField(
              controller: _ctrl,
              autofocus: true,
              placeholder: widget.dropoff
                  ? 'Nom, téléphone, lieu, quartier…'
                  : 'Lieu, quartier, rue, commerce…',
              onChanged: _onChanged,
              onSubmitted: (q) => _search(q.trim()),
              style: TextStyles.body.copyWith(color: p.label),
            ),
          ),
          if (widget.allowMap)
            InsetGroup(
              children: [
                GroupRow(
                  leading: IconBadge(CupertinoIcons.map, color: color),
                  title: 'Choisir sur la carte',
                  chevron: true,
                  onTap: () => Navigator.pop(context, chooseOnMap),
                ),
              ],
            ),
          if (widget.dropoff && _saved.isNotEmpty)
            InsetGroup(
              header: 'Mes destinataires',
              children: [
                for (final a in _saved.take(_query.isEmpty ? 6 : 20))
                  GroupRow(
                    leading: Avatar(a['recipientName'] ?? '?', radius: 16),
                    title: a['recipientName'],
                    subtitle: '${a['address']} · ${a['recipientPhone']}',
                    onTap: () => Navigator.pop(context, StopDraft.fromSaved(a)),
                  ),
              ],
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CupertinoActivityIndicator(),
            ),
          if (_results.isNotEmpty)
            InsetGroup(
              header: 'Lieux',
              children: [
                for (final r in _results)
                  GroupRow(
                    leading: IconBadge(
                      CupertinoIcons.location_solid,
                      color: p.blue,
                    ),
                    title: r.label,
                    subtitle: r.sublabel,
                    value: widget.near == null
                        ? null
                        : km(distanceKm(widget.near!, r.point)),
                    onTap: () => Navigator.pop(context, r),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
