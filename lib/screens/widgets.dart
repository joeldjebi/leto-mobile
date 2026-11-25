import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'profile_screen.dart';

export 'phone_field.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';

// ============================================================================
// Retours haptiques et pression
// ============================================================================

void hapticTap() => HapticFeedback.selectionClick();
void hapticSuccess() => HapticFeedback.mediumImpact();

/// Élément qui s'enfonce légèrement sous le doigt (retour visuel fluide)
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.96,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              hapticTap();
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _down ? 0.85 : 1,
          duration: const Duration(milliseconds: 120),
          child: widget.child,
        ),
      ),
    );
  }
}

// ============================================================================
// Carte
// ============================================================================

/// Carte OpenStreetMap (en couleur en clair, assombrie en sombre). Recherche et itinéraires : via l'API.
class LetoMap extends StatelessWidget {
  final MapController? controller;
  final LatLng center;
  final double zoom;
  final List<Widget> layers;
  final void Function(MapCamera camera, bool hasGesture)? onMove;
  final VoidCallback? onMoveEnd;
  final VoidCallback? onReady;

  const LetoMap({
    super.key,
    this.controller,
    this.center = abidjan,
    this.zoom = 13,
    this.layers = const [],
    this.onMove,
    this.onMoveEnd,
    this.onReady,
  });

  @override
  Widget build(BuildContext context) {
    loadMapStyle(); // rafraîchi au plus toutes les 5 min
    return ValueListenableBuilder<MapStyle>(
      valueListenable: mapStyle,
      builder: (context, style, _) => _map(context, style),
    );
  }

  Widget _map(BuildContext context, MapStyle style) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = dark && style.dark != null ? style.dark! : style.light;
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        backgroundColor: Palette.of(context).background,
        onPositionChanged: onMove,
        onMapEvent: onMoveEnd == null
            ? null
            : (e) {
                if (e is MapEventMoveEnd ||
                    e is MapEventFlingAnimationEnd ||
                    e is MapEventDoubleTapZoomEnd) {
                  onMoveEnd!();
                }
              },
        onMapReady: onReady,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          key: ValueKey(url),
          urlTemplate: url,
          subdomains: style.subdomains,
          maxNativeZoom: style.maxZoom.round(),
          userAgentPackageName: 'ci.leto.leto',
          // Pas de variante sombre chez ce fournisseur : on assombrit les tuiles claires
          tileBuilder: dark && style.dark == null ? darkModeTileBuilder : null,
          tileDisplay: const TileDisplay.fadeIn(
            duration: Duration(milliseconds: 220),
          ),
        ),
        ...layers,
        if (style.attribution.isNotEmpty)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 4),
              child: Text(
                style.attribution,
                style: TextStyle(
                  fontSize: 9,
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha: 0.45,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

Color stopColor(BuildContext context, String? status) {
  final p = Palette.of(context);
  return switch (status) {
    'DELIVERED' => p.green,
    'FAILED' => p.red,
    'CANCELLED' => p.tertiaryLabel,
    _ => accent,
  };
}

/// Départ (pastille noire « A »)
Marker pickupMarker(LatLng p) => Marker(
  point: p,
  width: 34,
  height: 34,
  child: const _Dot(label: 'A', color: ink),
);

/// Arrêt numéroté (violet = à livrer, vert = livré, rouge = échec)
Marker stopMarker(
  BuildContext context,
  LatLng p,
  int number, {
  String? status,
}) => Marker(
  point: p,
  width: 34,
  height: 34,
  child: _Dot(label: '$number', color: stopColor(context, status)),
);

class _Dot extends StatelessWidget {
  final String label;
  final Color color;
  const _Dot({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontFamily: 'Inter',
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );
}

/// Livreur (moto)
/// Icône de l'engin du livreur (MOTO, CAR, CARGO)
IconData vehicleIcon(String? vehicle) => switch (vehicle) {
  'CAR' => PhosphorIcons.carProfile(PhosphorIconsStyle.fill),
  'CARGO' => PhosphorIcons.truck(PhosphorIconsStyle.fill),
  _ => PhosphorIcons.motorcycle(PhosphorIconsStyle.fill),
};

/// Livreur de la course suivie : l'icône de son engin dans une pastille
Marker driverMarker(
  LatLng p, {
  String? vehicle,
  double? headingTurns,
  bool stale = false,
}) => Marker(
  point: p,
  width: 64,
  height: 64,
  child: Stack(
    alignment: Alignment.center,
    children: [
      // Sens de marche : une pointe qui tourne en douceur autour de la pastille
      if (headingTurns != null)
        AnimatedRotation(
          turns: headingTurns,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          child: const CustomPaint(
            size: Size(64, 64),
            painter: _HeadingPainter(),
          ),
        ),
      Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          // Grisé quand la position n'est plus à jour (signal perdu)
          color: stale ? const Color(0xFF8E8E93) : ink,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Icon(vehicleIcon(vehicle), color: Colors.white, size: 24),
      ),
    ],
  ),
);

class _HeadingPainter extends CustomPainter {
  const _HeadingPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.width / 2;
    final path = ui.Path()
      ..moveTo(c, 0)
      ..lineTo(c + 9, 12)
      ..lineTo(c - 9, 12)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Livreur disponible autour du client (carte d'accueil) : icône de son engin
Marker nearbyDriverMarker(LatLng p, String vehicle) => Marker(
  point: p,
  width: 40,
  height: 40,
  child: Container(
    decoration: ShapeDecoration(
      color: Colors.white,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(13)),
      shadows: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Icon(vehicleIcon(vehicle), color: ink, size: 26),
  ),
);

/// Client qui partage sa position avec le livreur (pastille bleue)
Marker clientMarker(LatLng p) => Marker(
  point: p,
  width: 40,
  height: 40,
  child: Semantics(
    label: 'Position du client',
    child: Container(
      decoration: BoxDecoration(
        color: ink,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: const Icon(
        CupertinoIcons.person_fill,
        color: Colors.white,
        size: 20,
      ),
    ),
  ),
);

/// Ma position (point violet)
Marker myMarker(LatLng p) => Marker(
  point: p,
  width: 26,
  height: 26,
  child: Container(
    decoration: BoxDecoration(
      color: accent,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3.5),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.3),
          blurRadius: 14,
          spreadRadius: 5,
        ),
      ],
    ),
  ),
);

/// Étiquette « 9 min · 6,4 km » posée sur la carte
Marker routeLabel(LatLng p, String text, Color color) => Marker(
  point: p,
  width: 124,
  height: 32,
  child: Container(
    alignment: Alignment.center,
    decoration: ShapeDecoration(
      color: color,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      shadows: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: 'Inter',
        color: Colors.white,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
    ),
  ),
);

/// Tracé d'un itinéraire
Widget routeLayer(List<LatLng> points, {Color color = accent}) => PolylineLayer(
  polylines: [
    Polyline(
      points: points,
      color: color,
      strokeWidth: 5.5,
      borderColor: Colors.white,
      borderStrokeWidth: 2.5,
    ),
  ],
);

/// Ajuste la carte pour voir tous les points
void fitPoints(
  MapController c,
  List<LatLng?> points, {
  EdgeInsets padding = const EdgeInsets.fromLTRB(50, 110, 50, 50),
}) {
  final pts = points.whereType<LatLng>().toList();
  if (pts.isEmpty) return;
  if (pts.length == 1) {
    c.move(pts.first, 15);
    return;
  }
  c.fitCamera(
    CameraFit.coordinates(coordinates: pts, padding: padding, maxZoom: 16),
  );
}

List<LatLng> latLngList(List points) => points
    .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
    .toList();

/// Épingle au centre de la carte : bulle (« Prise en charge · ~10 min »), tige, point,
/// et nom du lieu dessous. Se soulève pendant que la carte bouge.
class CenterPin extends StatelessWidget {
  final bool dropoff;
  final String title;
  final String? subtitle;
  final bool loading;
  final String? place;
  const CenterPin({
    super.key,
    this.dropoff = false,
    required this.title,
    this.subtitle,
    this.loading = false,
    this.place,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = dropoff ? accent : ink;
    final lifted = loading;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final cy = c.maxHeight / 2;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Bulle + tige
              AnimatedPositioned(
                duration: Motion.medium,
                curve: Motion.curve,
                left: 0,
                right: 0,
                bottom: c.maxHeight - cy + (lifted ? 12 : 4),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(6, 6, 18, 6),
                        decoration: ShapeDecoration(
                          color: p.card,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(22),
                          ),
                          shadows: const [
                            BoxShadow(
                              color: Color(0x26000000),
                              blurRadius: 24,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: ShapeDecoration(
                                color: dropoff ? letoFill : ink,
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              child: PhosphorIcon(
                                dropoff
                                    ? PhosphorIcons.flagCheckered(
                                        PhosphorIconsStyle.fill,
                                      )
                                    : PhosphorIcons.package(
                                        PhosphorIconsStyle.fill,
                                      ),
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  style: TextStyles.subheadline.copyWith(
                                    color: p.secondaryLabel,
                                  ),
                                ),
                                AnimatedSwitcher(
                                  duration: Motion.fast,
                                  child: loading
                                      ? const SizedBox(
                                          key: ValueKey('l'),
                                          width: 44,
                                          height: 24,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: CupertinoActivityIndicator(
                                              radius: 8,
                                            ),
                                          ),
                                        )
                                      : Text(
                                          subtitle ?? '',
                                          key: ValueKey(subtitle),
                                          style: TextStyles.title3.copyWith(
                                            color: p.label,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 3,
                        height: 18,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Point d'ancrage (reste fixe au centre)
              Positioned(
                left: c.maxWidth / 2 - 7,
                top: cy - 7,
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: lifted ? 0.25 : 0.15,
                        ),
                        blurRadius: lifted ? 8 : 4,
                      ),
                    ],
                  ),
                ),
              ),
              // Nom du lieu
              if (place != null && place!.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  top: cy + 14,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: lifted ? 0 : 1,
                      duration: Motion.fast,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 230),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: ShapeDecoration(
                          color: ink.withValues(alpha: 0.82),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          place!,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyles.subheadline.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================================
// Panneaux, boutons
// ============================================================================

/// Panneau blanc posé sur la carte (grands arrondis). Si [contentKey] change,
/// le contenu se remplace en fondu et le panneau change de taille en douceur.
class GlassPanel extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  final Object? contentKey;
  const GlassPanel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 14),
    this.contentKey,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final content = Column(
      key: ValueKey(contentKey),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 30,
            offset: Offset(0, -6),
          ),
        ],
      ),
      padding: padding,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Grabber(),
            const SizedBox(height: 14),
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: contentKey == null
                  ? content
                  : AnimatedSwitcher(
                      duration: Motion.medium,
                      switchInCurve: Motion.curve,
                      switchOutCurve: Curves.easeIn,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
                      child: content,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Poignée de feuille
class Grabber extends StatelessWidget {
  const Grabber({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 40,
      height: 5,
      decoration: BoxDecoration(
        color: Palette.of(context).separator,
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );
}

/// Bouton rond flottant sur la carte
class MapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const MapButton(this.icon, {super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      pressedScale: 0.9,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: p.card,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Icon(icon, color: p.label, size: 23),
      ),
    );
  }
}

/// Bouton secondaire « teinté » (fond accent léger)
class TintedButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  const TintedButton(
    this.label, {
    super.key,
    this.icon,
    this.onPressed,
    this.color = accent,
  });

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: icon == null ? null : Icon(icon, size: 19),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: color.withValues(alpha: 0.12),
      foregroundColor: color,
    ),
  );
}

// ============================================================================
// Listes groupées (Réglages)
// ============================================================================

/// Section de liste groupée, coins arrondis, séparateurs en retrait
class InsetGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;
  final EdgeInsets margin;
  const InsetGroup({
    super.key,
    this.header,
    this.footer,
    required this.children,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 18),
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Divider(height: 0.5, thickness: 0.5, color: p.separator),
          ),
        );
      }
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: Text(
                header!.toUpperCase(),
                style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
              ),
            ),
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: p.card,
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(
                footer!,
                style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// Icône carrée colorée façon Réglages
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconBadge(this.icon, {super.key, required this.color, this.size = 30});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: ShapeDecoration(
      color: color,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(size * 0.23),
      ),
    ),
    child: Icon(icon, color: Colors.white, size: size * 0.6),
  );
}

/// Ligne de liste : icône, titre, sous-titre, valeur, chevron
class GroupRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final Color? titleColor;
  final VoidCallback? onTap;
  const GroupRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.titleColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              hapticTap();
              onTap!();
            },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 42),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyles.body.copyWith(
                        color: titleColor ?? p.label,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: TextStyles.footnote.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Flexible(
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyles.body.copyWith(color: p.secondaryLabel),
                  ),
                ),
              ?trailing,
              if (chevron) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 17,
                  color: p.tertiaryLabel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Champ de saisie intégré à une liste groupée
class GroupField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final IconData? icon;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool obscure;
  final String? prefix;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  /// Bouton à droite du champ, sur la même ligne (ex. répertoire, position)
  final Widget? trailing;
  final TextCapitalization capitalization;
  const GroupField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.icon,
    this.keyboardType,
    this.validator,
    this.obscure = false,
    this.prefix,
    this.maxLines = 1,
    this.onChanged,
    this.trailing,
    this.capitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 16, right: trailing == null ? 16 : 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(top: 11, right: 12),
              child: Icon(icon, size: 20, color: p.secondaryLabel),
            ),
          if (prefix != null)
            Padding(
              padding: const EdgeInsets.only(top: 11, right: 8),
              child: Text(
                prefix!,
                style: TextStyles.body.copyWith(color: p.label),
              ),
            ),
          Expanded(
            child: TextFormField(
              controller: controller,
              obscureText: obscure,
              textCapitalization: capitalization,
              keyboardType: keyboardType,
              validator: validator,
              onChanged: onChanged,
              minLines: 1,
              maxLines: maxLines,
              style: TextStyles.body.copyWith(color: p.label),
              decoration: InputDecoration(
                hintText: placeholder,
                filled: false,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                errorStyle: TextStyles.footnote.copyWith(color: p.red),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Ligne avec interrupteur iOS
class GroupSwitch extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool> onChanged;
  const GroupSwitch({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => GroupRow(
    leading: leading,
    title: title,
    subtitle: subtitle,
    trailing: CupertinoSwitch(
      value: value,
      activeTrackColor: Palette.of(context).green,
      onChanged: (v) {
        hapticTap();
        onChanged(v);
      },
    ),
  );
}

// ============================================================================
// Pastilles, statuts
// ============================================================================

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Pill(this.text, {super.key, required this.color, this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: ShapeDecoration(
      color: color.withValues(alpha: 0.14),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyles.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// Paiement de la course : espèces uniquement
class CashPill extends StatelessWidget {
  const CashPill({super.key});
  @override
  Widget build(BuildContext context) => Pill(
    'Espèces',
    color: Palette.of(context).green,
    icon: CupertinoIcons.money_dollar_circle,
  );
}

/// « Encaisser 15 000 F » (paiement à la livraison)
class CodBadge extends StatelessWidget {
  final num amount;

  /// Devise de la course (code ISO), sinon celle du pays où LETO livre
  final String? currency;
  const CodBadge(this.amount, {super.key, this.currency});
  @override
  Widget build(BuildContext context) => Pill(
    'Encaisser ${formatMoney(amount, currency)}',
    color: accentDeep,
    icon: CupertinoIcons.creditcard,
  );
}

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = switch (status) {
      'PENDING' => p.secondaryLabel,
      'ACCEPTED' => p.blue,
      'PICKED_UP' => p.label,
      'DELIVERED' => p.green,
      _ => p.secondaryLabel,
    };
    return Pill(statusLabels[status] ?? status, color: color);
  }
}

/// Étapes : Demandée → Acceptée → Récupérée → Terminée
class StatusSteps extends StatelessWidget {
  final String status;
  const StatusSteps(this.status, {super.key});

  static const _order = ['PENDING', 'ACCEPTED', 'PICKED_UP', 'DELIVERED'];
  static const _labels = ['Demandée', 'Acceptée', 'Récupérée', 'Terminée'];

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final current = _order.indexOf(status);
    return Row(
      children: List.generate(_order.length, (i) {
        final done = i <= current;
        return Expanded(
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: done ? p.green : p.fill,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _labels[i],
                style: TextStyles.caption.copyWith(
                  color: done ? p.label : p.tertiaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// Ligne de point : départ (A) ou arrêt numéroté
class PointLine extends StatelessWidget {
  final String marker; // 'A' ou numéro d'arrêt
  final Color? color;
  final String title;
  final String? detail;
  final Widget? trailing;
  const PointLine({
    super.key,
    this.marker = 'A',
    this.color,
    required this.title,
    this.detail,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color ?? (marker == 'A' ? ink : accent),
              shape: BoxShape.circle,
            ),
            child: Text(
              marker,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyles.subheadline.copyWith(
                    color: p.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    style: TextStyles.footnote.copyWith(
                      color: p.secondaryLabel,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Carte compacte d'une course (historiques)
class DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback? onTap;
  const DeliveryCard(this.d, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final stops = (d['stops'] as List? ?? []).cast<Map<String, dynamic>>();
    final cod = stops.fold<num>(0, (s, x) => s + (x['codAmount'] ?? 0));
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusChip(d['status']),
                const SizedBox(width: 6),
                if (stops.length > 1)
                  Pill(
                    '${stops.length} arrêts',
                    color: p.blue,
                    icon: CupertinoIcons.map_pin_ellipse,
                  ),
                const Spacer(),
                Text(
                  formatMoney(d['price'], d['currency']),
                  style: TextStyles.headline.copyWith(color: p.label),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PointLine(title: d['pickupAddress'], detail: d['pickupCommune']),
            for (final s in stops)
              PointLine(
                marker: '${s['position'] + 1}',
                color: stopColor(context, s['status']),
                title: s['address'],
                detail: '${s['commune']} · ${s['recipientName']}',
              ),
            if (cod > 0) ...[
              const SizedBox(height: 6),
              CodBadge(cod, currency: d['currency']),
            ],
          ],
        ),
      ),
    );
  }
}

/// Miniature de photo (agrandissable)
class AddressPhoto extends StatelessWidget {
  final String path;
  final double size;
  const AddressPhoto(this.path, {super.key, this.size = 72});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl(path);
    return GestureDetector(
      onTap: () => showDialog(
        context: context,
        builder: (_) =>
            Dialog(child: InteractiveViewer(child: Image.network(url))),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            color: Palette.of(context).fill,
          ),
        ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final double radius;

  /// Photo de profil (/uploads/…), sinon l'initiale
  final String? photo;
  const Avatar(this.name, {super.key, this.radius = 20, this.photo});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return CircleAvatar(
      radius: radius,
      backgroundColor: p.fill,
      foregroundImage: photo == null ? null : NetworkImage(photoUrl(photo!)),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: TextStyle(
          color: p.label,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.8,
        ),
      ),
    );
  }
}

// ============================================================================
// Dialogues iOS
// ============================================================================

/// Feuille d'actions iOS ; renvoie la valeur choisie
Future<T?> showActions<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<(String, T, bool)> actions,
  String cancelLabel = 'Annuler',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: title == null ? null : Text(title),
      message: message == null ? null : Text(message),
      actions: [
        for (final (label, value, destructive) in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: destructive,
            onPressed: () => Navigator.pop(ctx, value),
            child: Text(label),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: Text(cancelLabel),
      ),
    ),
  );
}

/// Confirmation iOS
Future<bool> confirm(
  BuildContext context,
  String title, {
  String? message,
  String ok = 'Confirmer',
  bool destructive = false,
}) async {
  final res = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: destructive,
          isDefaultAction: !destructive,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return res == true;
}

/// Saisie de texte iOS (code, montant, note)
Future<String?> prompt(
  BuildContext context,
  String title, {
  String? message,
  String placeholder = '',
  String initial = '',
  TextInputType keyboard = TextInputType.text,
  String ok = 'Valider',
  bool large = false,
}) {
  final ctrl = TextEditingController(text: initial);
  return showCupertinoDialog<String>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Column(
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(message),
            ),
          CupertinoTextField(
            controller: ctrl,
            autofocus: true,
            placeholder: placeholder,
            keyboardType: keyboard,
            textAlign: large ? TextAlign.center : TextAlign.start,
            style: large
                ? const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 8,
                  )
                : null,
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Annuler'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(ok),
        ),
      ],
    ),
  );
}

// ============================================================================
// Écrans à grand titre
// ============================================================================

/// Écran iOS à grand titre qui se réduit au défilement
class LargeTitlePage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final Widget? bottomBar;
  final Future<void> Function()? onRefresh;

  /// Titre sur la même ligne que le bouton retour (au lieu du grand titre)
  final bool inline;
  const LargeTitlePage({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.bottomBar,
    this.onRefresh,
    this.inline = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Retour : icône seule, sans libellé
    final back = Navigator.canPop(context)
        ? CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            onPressed: () => Navigator.maybePop(context),
            child: Icon(CupertinoIcons.back, color: accent, size: 28),
          )
        : null;
    return Scaffold(
      backgroundColor: p.background,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          if (inline)
            SliverAppBar(
              pinned: true,
              backgroundColor: p.background,
              surfaceTintColor: Colors.transparent,
              leading: back,
              automaticallyImplyLeading: false,
              centerTitle: false,
              titleSpacing: back == null ? 16 : 0,
              title: Text(
                title,
                style: TextStyles.title3.copyWith(color: p.label),
              ),
              actions: [
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: trailing,
                  ),
              ],
            )
          else
            CupertinoSliverNavigationBar(
              largeTitle: Text(title, style: TextStyle(color: p.label)),
              backgroundColor: p.background.withValues(alpha: 0.85),
              border: null,
              trailing: trailing,
              leading: back,
              automaticallyImplyLeading: false,
            ),
          if (onRefresh != null)
            CupertinoSliverRefreshControl(onRefresh: onRefresh),
          SliverPadding(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            sliver: SliverList(delegate: SliverChildListDelegate(children)),
          ),
        ],
      ),
      bottomNavigationBar: bottomBar,
    );
  }
}

/// Barre du bas translucide (bouton principal)
class GlassBottomBar extends StatelessWidget {
  final Widget child;
  const GlassBottomBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Toujours visible pendant la saisie : la barre remonte au-dessus du clavier
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: p.glass,
              border: Border(top: BorderSide(color: p.separator, width: 0.5)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: SafeArea(top: false, child: child),
          ),
        ),
      ),
    );
  }
}

/// Historique (client ou livreur)
class HistoryScreen extends StatefulWidget {
  final Future<List<dynamic>> Function() load;
  final void Function(BuildContext, Map<String, dynamic>)? onTap;
  const HistoryScreen({super.key, required this.load, this.onTap});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await widget.load();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LargeTitlePage(
      title: 'Mes livraisons',
      onRefresh: _refresh,
      children: [
        if (_items == null)
          const Padding(
            padding: EdgeInsets.all(40),
            child: CupertinoActivityIndicator(),
          ),
        if (_items != null && _items!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              'Aucune livraison',
              textAlign: TextAlign.center,
              style: TextStyles.body.copyWith(color: p.secondaryLabel),
            ),
          ),
        ...?_items?.map(
          (d) => DeliveryCard(
            d,
            onTap: widget.onTap == null
                ? null
                : () => widget.onTap!(context, d),
          ),
        ),
      ],
    );
  }
}

/// Couleur des livreurs indépendants (toujours signalés au client)
const independentColor = sunOrange;

/// Badge « Livreur indépendant » : bien visible partout où le client voit le livreur
class IndependentBadge extends StatelessWidget {
  final bool large;
  const IndependentBadge({super.key, this.large = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: large ? 10 : 8,
      vertical: large ? 5 : 3,
    ),
    decoration: ShapeDecoration(
      color: independentColor,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.person_badge_minus_fill,
          size: large ? 15 : 12,
          color: const Color(0xFF1F1300),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            'LIVREUR INDÉPENDANT',
            overflow: TextOverflow.ellipsis,
            style: (large ? TextStyles.footnote : TextStyles.caption).copyWith(
              color: const Color(0xFF1F1300),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Encadré d'avertissement : ce que veut dire « livreur indépendant »
class IndependentNotice extends StatelessWidget {
  final EdgeInsets margin;
  const IndependentNotice({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 18),
  });

  static const text =
      'Ce livreur n’appartient à aucune entreprise partenaire. Son identité et son engin sont vérifiés par LETO. Pas de paiement à la livraison.';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: independentColor.withValues(alpha: 0.14),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: independentColor, width: 1.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IndependentBadge(large: true),
          const SizedBox(height: 8),
          Text(text, style: TextStyles.subheadline.copyWith(color: p.label)),
        ],
      ),
    );
  }
}

/// Feuille « Compte » (remplace le menu latéral) : profil + liens + déconnexion
Future<void> showAccountSheet(
  BuildContext context, {
  required List<(IconData, Color, String, VoidCallback)> items,
}) {
  final user = Api.instance.user ?? {};
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Palette.of(context).background,
    shape: const RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Grabber(),
            const SizedBox(height: 16),
            Avatar(user['name'] ?? '?', radius: 36, photo: user['avatarUrl']),
            const SizedBox(height: 10),
            Text(
              user['name'] ?? '',
              style: TextStyles.title2.copyWith(color: p.label),
            ),
            Text(
              formatPhone(user['phone']),
              style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
            ),
            const SizedBox(height: 22),
            InsetGroup(
              children: [
                GroupRow(
                  leading: IconBadge(
                    CupertinoIcons.person_crop_circle_fill,
                    color: accent,
                  ),
                  title: 'Mon profil',
                  chevron: true,
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ProfileScreen()),
                    );
                  },
                ),
                for (final (icon, color, label, onTap) in items)
                  GroupRow(
                    leading: IconBadge(icon, color: color),
                    title: label,
                    chevron: true,
                    onTap: () {
                      Navigator.pop(ctx);
                      onTap();
                    },
                  ),
              ],
            ),
            InsetGroup(
              children: [
                GroupRow(
                  title: 'Se déconnecter',
                  titleColor: p.red,
                  onTap: () async {
                    await Api.instance.logout();
                    if (ctx.mounted) goHome(ctx);
                  },
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
