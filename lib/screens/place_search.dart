import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';

/// Résultat spécial : l'utilisateur veut placer le point sur la carte
const chooseOnMap = 'map';

/// Recherche d'un lieu (Google Places + OpenStreetMap, via l'API).
/// Renvoie un [Place], ou [chooseOnMap].
class PlaceSearchScreen extends StatefulWidget {
  final String title;
  final LatLng? near;
  final bool dropoff;
  const PlaceSearchScreen({
    super.key,
    required this.title,
    this.near,
    this.dropoff = false,
  });

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _search(q.trim()),
    );
  }

  Future<void> _search(String q) async {
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    _lastQuery = q;
    setState(() => _loading = true);
    try {
      final res = await Api.instance.search(q, near: widget.near);
      if (mounted && q == _lastQuery) setState(() => _results = res);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted && q == _lastQuery) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.dropoff ? letoOrange : letoGreen;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (q) => _search(q.trim()),
              decoration: InputDecoration(
                hintText: 'Lieu, quartier, rue, commerce…',
                prefixIcon: Icon(
                  widget.dropoff ? Icons.flag : Icons.search,
                  color: color,
                ),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(Icons.map_outlined, color: color),
            ),
            title: const Text(
              'Choisir sur la carte',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: () => Navigator.pop(context, chooseOnMap),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (_, i) {
                final p = _results[i];
                return ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFF3F4F6),
                    child: Icon(Icons.place_outlined, color: letoDark),
                  ),
                  title: Text(
                    p.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    p.sublabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: widget.near == null
                      ? null
                      : Text(
                          km(distanceKm(widget.near!, p.point)),
                          style: const TextStyle(color: Colors.grey),
                        ),
                  onTap: () => Navigator.pop(context, p),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
