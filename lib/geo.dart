import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Centre d'Abidjan (Plateau)
const abidjan = LatLng(5.3364, -4.0267);

/// Centre approximatif de chaque commune — sert à deviner la commune d'un point sur la carte
const communeCenters = {
  'Abobo': LatLng(5.4180, -4.0200),
  'Adjamé': LatLng(5.3560, -4.0230),
  'Attécoubé': LatLng(5.3370, -4.0420),
  'Cocody': LatLng(5.3600, -3.9700),
  'Koumassi': LatLng(5.2950, -3.9500),
  'Marcory': LatLng(5.3000, -3.9830),
  'Plateau': LatLng(5.3230, -4.0190),
  'Port-Bouët': LatLng(5.2560, -3.9260),
  'Treichville': LatLng(5.2930, -4.0080),
  'Yopougon': LatLng(5.3450, -4.0890),
  'Bingerville': LatLng(5.3550, -3.8850),
  'Songon': LatLng(5.3200, -4.2600),
  'Anyama': LatLng(5.4950, -4.0520),
};

String nearestCommune(LatLng p) {
  const distance = Distance();
  return communeCenters.entries
      .reduce((a, b) => distance(p, a.value) <= distance(p, b.value) ? a : b)
      .key;
}

/// Position GPS actuelle, ou null si refusée / indisponible
Future<LatLng?> myPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
    final p = LatLng(pos.latitude, pos.longitude);
    // Hors zone de service (Grand Abidjan) : on garde la carte centrée sur Abidjan
    return const Distance().as(LengthUnit.Kilometer, p, abidjan) > 80 ? null : p;
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
