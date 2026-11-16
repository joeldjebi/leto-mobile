import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'realtime.dart';

/// API de production
const prodApiUrl = 'https://api.leto.performx.online';

/// URL de l'API : la production par défaut.
/// Développement : --dart-define=API_URL=local (votre Mac : localhost, ou 10.0.2.2 sur émulateur Android)
///                 ou --dart-define=API_URL=http://192.168.1.10:3000 (téléphone sur le même Wi-Fi).
final String apiUrl = switch (const String.fromEnvironment('API_URL')) {
  '' => prodApiUrl,
  'local' =>
    Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000',
  final url => url,
};

/// URL complète d'une photo stockée par l'API (/uploads/...)
String photoUrl(String path) => '$apiUrl$path';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Lieu (recherche ou point sur la carte)
class Place {
  final String label;
  final String sublabel;
  final LatLng point;
  const Place(this.label, this.sublabel, this.point);

  factory Place.fromJson(Map<String, dynamic> j) => Place(
    j['label'] ?? '',
    j['sublabel'] ?? '',
    LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
  );
}

/// Itinéraire calculé par l'API (Google ou OSRM)
class RouteInfo {
  final double distanceKm;
  final int durationMin;
  final List<LatLng> points;
  const RouteInfo(this.distanceKm, this.durationMin, this.points);

  factory RouteInfo.fromJson(Map<String, dynamic> j) => RouteInfo(
    (j['distanceKm'] as num).toDouble(),
    (j['durationMin'] as num).toInt(),
    (j['points'] as List)
        .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList(),
  );
}

class Api {
  Api._();
  static final instance = Api._();

  String? _token;
  Map<String, dynamic>? user;

  String? get token => _token;
  bool get isLoggedIn => _token != null && user != null;
  String get role => user?['role'] ?? '';

  /// Restaure la session au démarrage de l'app
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    if (_token == null) return;
    try {
      user = await _request('GET', '/auth/me');
    } catch (_) {
      await logout();
    }
  }

  Future<void> login(String phone, String password) => _saveSession(
    _request('POST', '/auth/login', {'phone': phone, 'password': password}),
  );

  Future<void> register(String name, String phone, String password) =>
      _saveSession(
        _request('POST', '/auth/register', {
          'name': name,
          'phone': phone,
          'password': password,
        }),
      );

  Future<void> logout() async {
    Realtime.instance.disconnect();
    _token = null;
    user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  Future<void> _saveSession(Future<dynamic> req) async {
    final res = await req;
    final u = res['user'] as Map<String, dynamic>;
    if (u['role'] != 'CLIENT' && u['role'] != 'DRIVER') {
      throw ApiException('Ce compte se connecte sur le tableau de bord web.');
    }
    _token = res['token'];
    user = u;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', _token!);
  }

  // ---------- Cartographie ----------
  Future<List<Place>> search(String q, {LatLng? near}) async {
    final params = {
      'q': q,
      if (near != null) 'lat': '${near.latitude}',
      if (near != null) 'lng': '${near.longitude}',
    };
    final res = await _request(
      'GET',
      '/geo/search?${Uri(queryParameters: params).query}',
    );
    return (res as List).map((j) => Place.fromJson(j)).toList();
  }

  Future<Place> reverse(LatLng p) async {
    final res = await _request(
      'GET',
      '/geo/reverse?lat=${p.latitude}&lng=${p.longitude}',
    );
    return Place(res['label'] ?? '', res['sublabel'] ?? '', p);
  }

  /// Itinéraire passant par plusieurs points (départ → arrêts)
  Future<RouteInfo> routeVia(List<LatLng> pts) async => RouteInfo.fromJson(
    await _request(
      'GET',
      '/geo/route-via?points=${pts.map((p) => '${p.latitude},${p.longitude}').join(';')}',
    ),
  );

  Future<RouteInfo> route(LatLng a, LatLng b) async => RouteInfo.fromJson(
    await _request(
      'GET',
      '/geo/route?fromLat=${a.latitude}&fromLng=${a.longitude}&toLat=${b.latitude}&toLng=${b.longitude}',
    ),
  );

  // ---------- Tarifs ----------
  /// Devis : ordre optimisé (`order`), itinéraire et prix de chaque offre
  Future<Map<String, dynamic>> quote(
    LatLng pickup,
    List<({LatLng point, bool cod})> stops,
  ) async => await _request('POST', '/pricing/quote', {
    'pickupLat': pickup.latitude,
    'pickupLng': pickup.longitude,
    'stops': [
      for (final s in stops)
        {'lat': s.point.latitude, 'lng': s.point.longitude, 'cod': s.cod},
    ],
  });

  /// Règles affichées dans l'app (attente avant absence, nombre max d'arrêts…)
  Future<Map<String, dynamic>> grid() async =>
      await _request('GET', '/pricing/grid');

  /// Délai de prise en charge (minutes) du livreur le plus proche, ou null
  Future<int?> eta(LatLng p) async => (await _request(
    'GET',
    '/pricing/eta?lat=${p.latitude}&lng=${p.longitude}',
  ))['minutes'];

  // ---------- Photos ----------
  Future<String> upload(File file) async {
    final req = http.MultipartRequest('POST', Uri.parse('$apiUrl/uploads'))
      ..headers['Authorization'] = 'Bearer $_token'
      ..files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          contentType: _imageType(file.path),
        ),
      );
    final res = await http.Response.fromStream(await req.send());
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        data['message']?.toString() ?? 'Échec de l’envoi de la photo',
      );
    }
    return data['url'];
  }

  MediaType _imageType(String path) {
    final ext = path.split('.').last.toLowerCase();
    return MediaType(
      'image',
      ext == 'png' ? 'png' : (ext == 'heic' ? 'heic' : 'jpeg'),
    );
  }

  // ---------- Client ----------
  Future<List<dynamic>> myDeliveries() async =>
      await _request('GET', '/deliveries/mine');
  Future<Map<String, dynamic>> getDelivery(String id) async =>
      await _request('GET', '/deliveries/mine/$id');
  Future<dynamic> createDelivery(Map<String, dynamic> body) =>
      _request('POST', '/deliveries', body);
  Future<dynamic> cancel(String id) =>
      _request('POST', '/deliveries/$id/cancel');
  Future<dynamic> disputeStop(String id, String stopId, String? note) =>
      _request('POST', '/deliveries/$id/stops/$stopId/dispute', {
        'note': ?note,
      });

  // ---------- Carnet d'adresses ----------
  Future<List<dynamic>> addresses({String q = ''}) async => await _request(
    'GET',
    '/addresses?${Uri(queryParameters: {'q': q}).query}',
  );
  Future<dynamic> deleteAddress(String id) =>
      _request('DELETE', '/addresses/$id');

  // ---------- Livreur ----------
  Future<List<dynamic>> available() async =>
      await _request('GET', '/deliveries/available');
  Future<List<dynamic>> driverDeliveries() async =>
      await _request('GET', '/deliveries/driver');
  Future<dynamic> accept(String id) =>
      _request('POST', '/deliveries/$id/accept');
  Future<dynamic> pickup(String id) =>
      _request('POST', '/deliveries/$id/pickup');
  Future<dynamic> deliverStop(String id, String stopId, String code) =>
      _request('POST', '/deliveries/$id/stops/$stopId/deliver', {'code': code});
  Future<dynamic> failStop(
    String id,
    String stopId, {
    required String reason,
    required String photoUrl,
    String? note,
  }) => _request('POST', '/deliveries/$id/stops/$stopId/fail', {
    'reason': reason,
    'photoUrl': photoUrl,
    'note': ?note,
  });

  // ---------- Proposez votre prix ----------
  Future<dynamic> proposePrice(String deliveryId, int price) =>
      _request('POST', '/deliveries/$deliveryId/offers', {'price': price});
  Future<List<dynamic>> myOffers() async =>
      await _request('GET', '/offers/mine');
  Future<List<dynamic>> offersFor(String deliveryId) async =>
      await _request('GET', '/deliveries/$deliveryId/offers');
  Future<dynamic> acceptOffer(String offerId) =>
      _request('POST', '/offers/$offerId/accept');
  Future<dynamic> declineOffer(String offerId) =>
      _request('POST', '/offers/$offerId/decline');

  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final req = http.Request(method, Uri.parse('$apiUrl$path'))
      ..headers['Content-Type'] = 'application/json';
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    if (body != null) req.body = jsonEncode(body);

    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 15)),
      );
    } catch (_) {
      throw ApiException(
        'Impossible de joindre le serveur. Vérifiez votre connexion.',
      );
    }
    final data = res.body.isEmpty
        ? null
        : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final msg = data is Map ? data['message'] : null;
      throw ApiException(
        msg is List
            ? msg.join('\n')
            : (msg?.toString() ?? 'Erreur ${res.statusCode}'),
      );
    }
    return data;
  }
}
