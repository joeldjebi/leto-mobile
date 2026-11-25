import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../geo.dart';
import '../main.dart';
import 'widgets.dart';

/// Choisir une adresse en déplaçant la carte sous l'épingle. Renvoie un [Place].
class MapPickerScreen extends StatefulWidget {
  final String title;
  final LatLng initial;
  final bool dropoff;
  const MapPickerScreen({
    super.key,
    required this.title,
    required this.initial,
    this.dropoff = true,
  });

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  final _map = MapController();
  late LatLng _center = widget.initial;
  Place? _place;
  bool _moving = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    final seq = ++_seq;
    final p = _center;
    try {
      final place = await Api.instance.reverse(p);
      if (mounted && seq == _seq) setState(() => _place = place);
    } catch (_) {}
  }

  Future<void> _locateMe() async {
    final me = await myPosition();
    if (me == null || !mounted) return;
    _map.move(me, 17);
    _center = me;
    _lookup();
  }

  void _confirm() {
    hapticTap();
    Navigator.pop(
      context,
      Place(
        _place?.label ?? 'Point sur la carte',
        _place?.sublabel ?? '',
        _center,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.background,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                LetoMap(
                  controller: _map,
                  center: widget.initial,
                  zoom: 17,
                  onMove: (camera, hasGesture) {
                    _center = camera.center;
                    if (hasGesture && !_moving) setState(() => _moving = true);
                  },
                  onMoveEnd: () {
                    setState(() => _moving = false);
                    _lookup();
                  },
                ),
                CenterPin(
                  dropoff: widget.dropoff,
                  title: widget.title,
                  subtitle: widget.dropoff ? 'Livrer ici' : 'Récupérer ici',
                  loading: _moving,
                  place: _moving ? null : _place?.label,
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        MapButton(
                          PhosphorIconsBold.arrowLeft,
                          onTap: () => Navigator.pop(context),
                        ),
                        const Spacer(),
                        MapButton(
                          PhosphorIconsBold.navigationArrow,
                          onTap: _locateMe,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          GlassPanel(
            children: [
              Text(
                widget.title.toUpperCase(),
                style: TextStyles.displaySmall.copyWith(color: p.label),
              ),
              const SizedBox(height: 6),
              Text(
                _moving
                    ? 'Déplacez la carte…'
                    : (_place?.label ?? 'Recherche de l’adresse…'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyles.title3.copyWith(
                  color: p.label,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (!_moving && (_place?.sublabel ?? '').isNotEmpty)
                Text(
                  _place!.sublabel,
                  style: TextStyles.subheadline.copyWith(
                    color: p.secondaryLabel,
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _moving ? null : _confirm,
                child: const Text('Valider cette adresse'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
