import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'api.dart';

/// Projection d'une position GPS sur un itinéraire
class RouteFix {
  /// Point le plus proche sur l'itinéraire (position « recalée » sur la route)
  final LatLng snapped;

  /// Distance entre la position GPS et l'itinéraire (m)
  final double offRouteM;

  /// Distance restante jusqu'à l'arrivée en suivant l'itinéraire (m)
  final double remainingM;

  /// Index du segment de l'itinéraire où se trouve la position
  final int segment;

  const RouteFix(this.snapped, this.offRouteM, this.remainingM, this.segment);
}

/// Itinéraire en direct vers une cible (départ, prochain destinataire) :
///  - recale la position sur la route (le marqueur suit la chaussée au lieu de couper les pâtés de maisons) ;
///  - « consomme » l'itinéraire au fil du trajet (seule la partie restante est dessinée) ;
///  - temps et distance restants mis à jour à chaque position ;
///  - recalcul automatique si le livreur quitte l'itinéraire ou change de cible.
class LiveRoute {
  LiveRoute({
    this.offRouteM = 45,
    this.minRefetch = const Duration(seconds: 12),
  });

  /// Au-delà de cette distance à la route, on considère que le livreur a pris un autre chemin
  final double offRouteM;

  /// Délai minimal entre deux calculs d'itinéraire (économise l'API)
  final Duration minRefetch;

  RouteInfo? route;
  LatLng? target;
  RouteFix? fix;

  /// Distance cumulée depuis chaque point jusqu'à l'arrivée (m)
  List<double> _toEnd = const [];
  DateTime _fetchedAt = DateTime(2000);
  int _offCount = 0;
  bool _loading = false;

  bool get hasRoute => route != null && route!.points.length >= 2;

  /// Partie restante de l'itinéraire, depuis la position recalée
  List<LatLng> get remaining {
    final r = route, f = fix;
    if (r == null) return const [];
    if (f == null) return r.points;
    return [f.snapped, ...r.points.skip(f.segment + 1)];
  }

  double? get remainingM =>
      fix?.remainingM ?? (route == null ? null : route!.distanceKm * 1000);

  /// Temps restant : durée de l'itinéraire au prorata de la distance restante (vitesse moyenne réelle du trajet)
  int? get etaMin {
    final r = route, m = remainingM;
    if (r == null || m == null) return null;
    if (r.distanceKm <= 0) return 1;
    return math.max(1, (r.durationMin * m / (r.distanceKm * 1000)).ceil());
  }

  /// Nouvelle position : met à jour la projection. Renvoie true s'il faut recalculer l'itinéraire.
  bool update(LatLng pos, LatLng newTarget) {
    if (target == null || distanceM(target!, newTarget) > 15) {
      target = newTarget;
      return true;
    }
    final r = route;
    if (r == null || r.points.length < 2) return !_loading;
    fix = _project(pos, r.points);
    // Deux positions de suite hors de la route : on recalcule (une seule peut être un saut GPS)
    _offCount = fix!.offRouteM > offRouteM ? _offCount + 1 : 0;
    final stale =
        DateTime.now().difference(_fetchedAt) > const Duration(minutes: 3);
    return (_offCount >= 2 || stale) &&
        DateTime.now().difference(_fetchedAt) > minRefetch;
  }

  /// Calcule l'itinéraire depuis [from] vers la cible courante
  Future<bool> fetch(LatLng from) async {
    final to = target;
    if (to == null || _loading) return false;
    _loading = true;
    try {
      final r = await Api.instance.route(from, to);
      if (target != to) return false; // la cible a changé entre-temps
      setRoute(r);
      fix = _project(from, r.points);
      return true;
    } catch (_) {
      return false;
    } finally {
      _fetchedAt = DateTime.now();
      _offCount = 0;
      _loading = false;
    }
  }

  void clear() {
    route = null;
    target = null;
    fix = null;
    _toEnd = const [];
  }

  /// Itinéraire connu (calculé ailleurs, ou pour les tests)
  void setRoute(RouteInfo r) {
    route = r;
    _fetchedAt = DateTime.now();
    final pts = r.points;
    final acc = List<double>.filled(pts.length, 0);
    for (var i = pts.length - 2; i >= 0; i--) {
      acc[i] = acc[i + 1] + distanceM(pts[i], pts[i + 1]);
    }
    _toEnd = acc;
  }

  RouteFix _project(LatLng p, List<LatLng> pts) {
    // Plan local (mètres) autour de la position : assez précis à l'échelle d'une ville
    final k = 111320.0, kx = k * math.cos(p.latitude * math.pi / 180);
    var best = double.infinity;
    var bestSeg = 0;
    var bestT = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final ax = (pts[i].longitude - p.longitude) * kx,
          ay = (pts[i].latitude - p.latitude) * k;
      final bx = (pts[i + 1].longitude - p.longitude) * kx,
          by = (pts[i + 1].latitude - p.latitude) * k;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
      final cx = ax + dx * t, cy = ay + dy * t;
      final d = cx * cx + cy * cy;
      if (d < best) {
        best = d;
        bestSeg = i;
        bestT = t;
      }
    }
    final a = pts[bestSeg], b = pts[bestSeg + 1];
    final snapped = LatLng(
      a.latitude + (b.latitude - a.latitude) * bestT,
      a.longitude + (b.longitude - a.longitude) * bestT,
    );
    final rest = _toEnd.length == pts.length ? _toEnd[bestSeg + 1] : 0.0;
    return RouteFix(
      snapped,
      math.sqrt(best),
      rest + distanceM(snapped, b),
      bestSeg,
    );
  }
}

/// Distance en mètres entre deux points
double distanceM(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b);
