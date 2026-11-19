import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:leto/api.dart';
import 'package:leto/live_route.dart';

void main() {
  // Itinéraire en L : 1 km vers l'est puis 1 km vers le nord (≈ 2 km, 10 min)
  const a = LatLng(5.3000, -4.0000);
  const b = LatLng(5.3000, -3.99098); // ≈ 1 km à l'est
  const c = LatLng(5.30904, -3.99098); // ≈ 1 km au nord
  LiveRoute make() {
    final r = LiveRoute(minRefetch: Duration.zero)
      ..setRoute(const RouteInfo(2.0, 10, [a, b, c]));
    r.target = c;
    return r;
  }

  test('position sur la route : recalée, reste du trajet et temps restant', () {
    final r = make();
    // 20 m au nord du milieu du premier segment
    final needRoute = r.update(const LatLng(5.30018, -3.99549), c);
    expect(needRoute, isFalse);
    expect(r.fix!.offRouteM, closeTo(20, 3));
    expect(r.fix!.snapped.latitude, closeTo(5.3000, 1e-6));
    expect(r.remainingM, closeTo(1500, 40));
    expect(r.etaMin, 8); // 10 min × 1,5/2 km, arrondi au-dessus
    expect(r.remaining.first, r.fix!.snapped);
    expect(r.remaining.last, c);
  });

  test('le trajet se « consomme » : seul le reste est dessiné', () {
    final r = make();
    r.update(const LatLng(5.3045, -3.99098), c); // milieu du 2e segment
    expect(r.remaining.length, 2);
    expect(r.remainingM, closeTo(500, 30));
  });

  test('hors de la route deux fois de suite : recalcul demandé', () {
    final r = make();
    const away = LatLng(5.3050, -3.9990); // ≈ 500 m de l'itinéraire
    expect(
      r.update(away, c),
      isFalse,
    ); // une seule mesure : peut être un saut GPS
    expect(r.update(away, c), isTrue);
  });

  test('nouvelle cible (étape suivante) : recalcul demandé', () {
    final r = make();
    expect(r.update(a, const LatLng(5.32, -3.98)), isTrue);
  });
}
