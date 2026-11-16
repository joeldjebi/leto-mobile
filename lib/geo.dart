import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Centre d'Abidjan (Plateau)
const abidjan = LatLng(5.3364, -4.0267);

const _distance = Distance();

/// Distance à vol d'oiseau en km
double distanceKm(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Meter, a, b) / 1000;

/// Dev / tests uniquement : position simulée avec --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
const _devLat = String.fromEnvironment('DEV_LAT');
const _devLng = String.fromEnvironment('DEV_LNG');
final LatLng? devPosition = _devLat.isEmpty
    ? null
    : LatLng(double.parse(_devLat), double.parse(_devLng));

/// Position GPS actuelle, ou null si refusée / indisponible / hors du Grand Abidjan
Future<LatLng?> myPosition() async {
  if (devPosition != null) return devPosition;
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition().timeout(
      const Duration(seconds: 10),
    );
    final p = LatLng(pos.latitude, pos.longitude);
    // Hors zone de service : on garde la carte centrée sur Abidjan
    return distanceKm(p, abidjan) > 80 ? null : p;
  } catch (_) {
    return null;
  }
}

/// Lit les coordonnées "pickup" ou "dropoff" d'une course
LatLng? pointOf(Map d, String prefix) {
  final lat = d['${prefix}Lat'], lng = d['${prefix}Lng'];
  if (lat == null || lng == null) return null;
  return LatLng((lat as num).toDouble(), (lng as num).toDouble());
}
