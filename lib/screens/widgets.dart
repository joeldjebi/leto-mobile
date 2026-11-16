import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../geo.dart';
import '../labels.dart';
import '../main.dart';

// ============================================================================
// Retours haptiques
// ============================================================================

void hapticTap() => HapticFeedback.selectionClick();
void hapticSuccess() => HapticFeedback.mediumImpact();

// ============================================================================
// Carte
// ============================================================================

/// Carte OpenStreetMap (assombrie en mode sombre). Recherche et itinéraires : via l'API.
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
    final dark = Theme.of(context).brightness == Brightness.dark;
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
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'ci.leto.leto',
          tileBuilder: dark ? darkModeTileBuilder : null,
        ),
        ...layers,
      ],
    );
  }
}

Color stopColor(BuildContext context, String? status) {
  final p = Palette.of(context);
  return switch (status) {
    'DELIVERED' => p.green,
    'FAILED' => p.red,
    _ => letoOrange,
  };
}

/// Départ (pastille verte « A »)
Marker pickupMarker(LatLng p) => Marker(
  point: p,
  width: 34,
  height: 34,
  child: const _Dot(label: 'A', color: Color(0xFF34C759)),
);

/// Arrêt numéroté (orange = à livrer, vert = livré, rouge = échec)
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
          color: Color(0x40000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: 13,
      ),
    ),
  );
}

/// Livreur (moto)
Marker driverMarker(LatLng p) => Marker(
  point: p,
  width: 44,
  height: 44,
  child: Container(
    decoration: BoxDecoration(
      color: const Color(0xFF1C1C1E),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [
        BoxShadow(
          color: Color(0x59000000),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: const Icon(Icons.two_wheeler, color: Colors.white, size: 22),
  ),
);

/// Ma position (point bleu façon Plans)
Marker myMarker(LatLng p) => Marker(
  point: p,
  width: 26,
  height: 26,
  child: Container(
    decoration: BoxDecoration(
      color: const Color(0xFF007AFF),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3.5),
      boxShadow: const [
        BoxShadow(color: Color(0x40007AFF), blurRadius: 12, spreadRadius: 4),
      ],
    ),
  ),
);

/// Étiquette « 9 min · 6,4 km » posée sur la carte
Marker routeLabel(LatLng p, String text, Color color) => Marker(
  point: p,
  width: 120,
  height: 30,
  child: Container(
    alignment: Alignment.center,
    decoration: ShapeDecoration(
      color: color,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(10)),
      shadows: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    ),
  ),
);

/// Tracé d'un itinéraire
Widget routeLayer(
  List<LatLng> points, {
  Color color = const Color(0xFF007AFF),
}) => PolylineLayer(
  polylines: [
    Polyline(
      points: points,
      color: color,
      strokeWidth: 6,
      borderColor: Colors.white,
      borderStrokeWidth: 2,
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

/// Épingle fixe au centre de la carte, avec une bulle (ex. « Prise en charge · ~10 min »)
class CenterPin extends StatelessWidget {
  final bool dropoff;
  final String title;
  final String? subtitle;
  final bool loading;
  const CenterPin({
    super.key,
    this.dropoff = false,
    required this.title,
    this.subtitle,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = dropoff ? letoOrange : p.green;
    return IgnorePointer(
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -44),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                    decoration: BoxDecoration(
                      color: p.glass,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: ShapeDecoration(
                            color: color,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Icon(
                            dropoff
                                ? CupertinoIcons.flag_fill
                                : Icons.two_wheeler,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyles.footnote.copyWith(
                                color: p.secondaryLabel,
                              ),
                            ),
                            loading
                                ? const SizedBox(
                                    width: 40,
                                    height: 20,
                                    child: CupertinoActivityIndicator(
                                      radius: 8,
                                    ),
                                  )
                                : Text(
                                    subtitle ?? '',
                                    style: TextStyles.headline.copyWith(
                                      color: p.label,
                                    ),
                                  ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(width: 3, height: 14, color: color),
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Panneaux en verre dépoli, boutons
// ============================================================================

/// Panneau translucide (flou) posé sur la carte, façon Plans
class GlassPanel extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  const GlassPanel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          width: double.infinity,
          color: p.glass,
          padding: padding,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Grabber(),
                const SizedBox(height: 10),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Poignée de feuille iOS
class Grabber extends StatelessWidget {
  const Grabber({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 36,
      height: 5,
      decoration: BoxDecoration(
        color: Palette.of(context).tertiaryLabel,
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );
}

/// Bouton rond translucide sur la carte
class MapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const MapButton(this.icon, {super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () {
        hapticTap();
        onTap();
      },
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: p.glass, shape: BoxShape.circle),
            child: Icon(icon, color: p.label, size: 21),
          ),
        ),
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
    this.color = letoOrange,
  });

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: icon == null ? null : Icon(icon, size: 19),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: color.withValues(alpha: 0.14),
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
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 22),
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
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                Text(
                  value!,
                  style: TextStyles.body.copyWith(color: p.secondaryLabel),
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
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(top: 13, right: 12),
              child: Icon(icon, size: 20, color: p.secondaryLabel),
            ),
          if (prefix != null)
            Padding(
              padding: const EdgeInsets.only(top: 13, right: 8),
              child: Text(
                prefix!,
                style: TextStyles.body.copyWith(color: p.label),
              ),
            ),
          Expanded(
            child: TextFormField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              validator: validator,
              minLines: 1,
              maxLines: maxLines,
              style: TextStyles.body.copyWith(color: p.label),
              decoration: InputDecoration(
                hintText: placeholder,
                filled: false,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                errorStyle: TextStyles.footnote.copyWith(color: p.red),
              ),
            ),
          ),
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
  const CodBadge(this.amount, {super.key});
  @override
  Widget build(BuildContext context) => Pill(
    'Encaisser ${fcfa(amount)}',
    color: const Color(0xFFC25E00),
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
      'PENDING' => const Color(0xFFC79100),
      'ACCEPTED' => p.blue,
      'PICKED_UP' => const Color(0xFFAF52DE),
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
              color: color ?? (marker == 'A' ? p.green : letoOrange),
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
                  fcfa(d['price']),
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
            if (cod > 0) ...[const SizedBox(height: 6), CodBadge(cod)],
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
  const Avatar(this.name, {super.key, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return CircleAvatar(
      radius: radius,
      backgroundColor: p.fill,
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
        child: const Text('Annuler'),
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
  const LargeTitlePage({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.bottomBar,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.background,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(title, style: TextStyle(color: p.label)),
            backgroundColor: p.background.withValues(alpha: 0.85),
            border: null,
            trailing: trailing,
            previousPageTitle: 'Retour',
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
    return ClipRect(
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
            Avatar(user['name'] ?? '?', radius: 36),
            const SizedBox(height: 10),
            Text(
              user['name'] ?? '',
              style: TextStyles.title2.copyWith(color: p.label),
            ),
            Text(
              '+225 ${user['phone'] ?? ''}',
              style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
            ),
            const SizedBox(height: 22),
            InsetGroup(
              children: [
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
