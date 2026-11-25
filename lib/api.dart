import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_activity.dart';
import 'notifications.dart';
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
/// Lien de suivi public d'une course (à partager au client ou aux destinataires)
String? trackingUrl(Map d) {
  final token = d['trackingToken'];
  if (token == null) return null;
  // Site public (l'espace sa.leto… est réservé à l'administration)
  final base = apiUrl == prodApiUrl
      ? 'https://leto.performx.online'
      : apiUrl.replaceFirst(':3000', ':5173');
  return '$base/#/suivi/$token';
}

/// Fond de carte choisi par le SA (OpenStreetMap, Carto, MapTiler, Mapbox, Google)
class MapStyle {
  final String provider;
  final String light;
  final String? dark; // null : le client assombrit les tuiles claires
  final List<String> subdomains;
  final double maxZoom;
  final String attribution;
  const MapStyle({
    required this.provider,
    required this.light,
    this.dark,
    this.subdomains = const [],
    this.maxZoom = 19,
    this.attribution = '© OpenStreetMap',
  });

  static const osm = MapStyle(
    provider: 'osm',
    light: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  factory MapStyle.fromJson(Map<String, dynamic> j) => MapStyle(
    provider: j['provider'] ?? 'osm',
    light: j['light'] ?? osm.light,
    dark: j['dark'],
    subdomains: (j['subdomains'] as List? ?? []).cast<String>(),
    maxZoom: (j['maxZoom'] as num?)?.toDouble() ?? 19,
    attribution: j['attribution'] ?? '',
  );
}

/// Fond de carte actuel (les cartes se redessinent quand il change)
final mapStyle = ValueNotifier<MapStyle>(MapStyle.osm);
DateTime? _mapStyleLoadedAt;

/// Charge le fond de carte choisi par le SA (au démarrage, puis au plus toutes les 5 min)
Future<void> loadMapStyle({bool force = false}) async {
  final last = _mapStyleLoadedAt;
  if (!force && last != null && DateTime.now().difference(last).inMinutes < 5)
    return;
  _mapStyleLoadedAt = DateTime.now();
  try {
    final res = await http
        .get(Uri.parse('$apiUrl/geo/map-style'))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode == 200) {
      mapStyle.value = MapStyle.fromJson(jsonDecode(res.body));
    }
  } catch (_) {
    // Hors ligne : on garde le fond actuel
  }
}

/// Livreur affiché sur la carte du client : position et engin (MOTO, CAR, CARGO)
typedef NearbyDriver = ({LatLng point, String vehicle});

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

/// Choix du client « Livreurs indépendants » (à la place d'une entreprise)
const kIndependentId = 'independent';

class Api {
  Api._();
  static final instance = Api._();

  String? _token;
  Map<String, dynamic>? user;

  String? get token => _token;
  bool get isLoggedIn => _token != null && user != null;
  String get role => user?['role'] ?? '';

  /// Livreur indépendant (pas rattaché à une entreprise)
  bool get isIndependent =>
      role == 'DRIVER' && user?['company']?['independent'] == true;

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

  /// Inscription d'un client : [accountType] = INDIVIDUAL (particulier) ou SHOP (boutique)
  Future<void> register(
    String name,
    String phone,
    String password,
    String accountType,
  ) => _saveSession(
    _request('POST', '/auth/register', {
      'name': name,
      'phone': phone,
      'password': password,
      'accountType': accountType,
    }),
  );

  /// Mise à jour du profil (nom, type, numéro, mot de passe)
  Future<void> updateProfile(Map<String, dynamic> changes) async {
    user = await _request('PATCH', '/auth/me', changes);
  }

  Future<void> logout() async {
    LetoNotifier.instance.detach();
    DeliveryLive.instance.end();
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
    List<({LatLng point, bool cod})> stops, {
    String? companyId,
  }) async => await _request('POST', '/pricing/quote', {
    // Indépendants : règles LETO par défaut (pas de grille d'entreprise)
    if (companyId != kIndependentId) 'companyId': ?companyId,
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

  /// Livreurs en ligne autour d'un point (positions anonymes), éventuellement d'une seule entreprise
  Future<List<NearbyDriver>> nearbyDrivers(
    LatLng p, {
    String? companyId,
  }) async {
    final res = await _request(
      'GET',
      '/pricing/drivers?lat=${p.latitude}&lng=${p.longitude}${companyId == null
          ? ''
          : companyId == kIndependentId
          ? '&independent=1'
          : '&companyId=$companyId'}',
    );
    return (res as List)
        .map(
          (d) => (
            point: LatLng(
              (d['lat'] as num).toDouble(),
              (d['lng'] as num).toDouble(),
            ),
            vehicle: (d['vehicle'] ?? 'MOTO') as String,
          ),
        )
        .toList();
  }

  // ---------- Photos ----------
  /// Photo d'un document d'identité (stockée à part, jamais publique)
  Future<String> uploadIdentity(File file) => upload(file, identity: true);

  Future<String> upload(File file, {bool identity = false}) async {
    final req =
        http.MultipartRequest(
            'POST',
            Uri.parse('$apiUrl/uploads${identity ? '/identity' : ''}'),
          )
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
  Future<dynamic> cancel(String id, {String? reason}) =>
      _request('POST', '/deliveries/$id/cancel', {'reason': ?reason});

  /// Motifs d'annulation définis par l'admin : {client: [...], driver: [...]}
  Future<Map<String, dynamic>> cancelReasons() async =>
      Map<String, dynamic>.from(await _request('GET', '/cancel-reasons'));

  /// Entreprises de livraison (choix du client) : livreurs en ligne, réussite, prix indicatifs
  Future<List<dynamic>> companiesDirectory() async =>
      await _request('GET', '/companies/directory');

  /// Course adressée à une entreprise sans réponse : l'ouvrir à toutes
  /// Note du livreur après la livraison (1 à 5 étoiles, compliments, commentaire)
  Future<Map<String, dynamic>> rate(
    String id, {
    required int stars,
    List<String> tags = const [],
    String comment = '',
  }) async => await _request('POST', '/deliveries/$id/rate', {
    'stars': stars,
    if (tags.isNotEmpty) 'tags': tags,
    if (comment.trim().isNotEmpty) 'comment': comment.trim(),
  });

  Future<dynamic> openToAll(String id) =>
      _request('POST', '/deliveries/$id/open-to-all');

  /// Frais éventuels si la course est annulée maintenant
  Future<dynamic> cancelPreview(String id) =>
      _request('GET', '/deliveries/mine/$id/cancel-preview');
  Future<dynamic> cancelStop(String id, String stopId, {String? reason}) =>
      _request('POST', '/deliveries/$id/stops/$stopId/cancel', {
        'reason': ?reason,
      });
  Future<dynamic> answerCancelRequest(String id, String stopId, bool accept) =>
      _request('POST', '/deliveries/$id/stops/$stopId/cancel-request/answer', {
        'accept': accept,
      });
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
  /// L'entreprise peut-elle travailler ? (abonnement actif, crédit disponible)
  Future<dynamic> billingStatus() => _request('GET', '/billing/driver-status');
  Future<List<dynamic>> available() async =>
      await _request('GET', '/deliveries/available');
  Future<List<dynamic>> driverDeliveries() async =>
      await _request('GET', '/deliveries/driver');
  Future<dynamic> accept(String id) =>
      _request('POST', '/deliveries/$id/accept');

  /// Tournée du livreur : ordre de passage de toutes ses courses en cours
  Future<Map<String, dynamic>> driverPlan() async => Map<String, dynamic>.from(
    await _request('GET', '/deliveries/driver/plan'),
  );
  Future<Map<String, dynamic>> saveDriverPlan(List<String> keys) async =>
      Map<String, dynamic>.from(
        await _request('PUT', '/deliveries/driver/plan', {'keys': keys}),
      );
  Future<Map<String, dynamic>> optimizeDriverPlan() async =>
      Map<String, dynamic>.from(
        await _request('POST', '/deliveries/driver/plan/optimize'),
      );

  /// Réponse à l'alerte « nouvelle course » (refusée, expirée) : statistiques de réactivité
  Future<void> alertResponse(String id, String action) async {
    try {
      await _request('POST', '/deliveries/$id/alert', {'action': action});
    } catch (_) {}
  }

  Future<dynamic> pickup(String id) =>
      _request('POST', '/deliveries/$id/pickup');

  /// [code] vide : livraison sans code (si l'admin a désactivé la confirmation par code)
  Future<dynamic> deliverStop(String id, String stopId, String code) =>
      _request('POST', '/deliveries/$id/stops/$stopId/deliver', {
        if (code.isNotEmpty) 'code': code,
      });

  /// Confirmation de livraison par le code du destinataire (réglage de l'admin)
  bool deliveryCodeEnabled = true;
  Future<void> loadDeliverySettings() async {
    try {
      final g = await grid();
      deliveryCodeEnabled = g['deliveryCodeEnabled'] != false;
    } catch (_) {}
  }

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

  /// Le destinataire annule : demande de confirmation envoyée à l'expéditeur
  Future<dynamic> requestStopCancel(String id, String stopId, {String? note}) =>
      _request('POST', '/deliveries/$id/stops/$stopId/cancel-request', {
        'note': ?note,
      });

  // ---------- Notifications ----------
  /// Sons des notifications (3 sons LETO intégrés + sons ajoutés par l'admin)
  Future<Map<String, dynamic>> notificationSounds() async =>
      (await _request('GET', '/notifications/sounds')) as Map<String, dynamic>;

  // ---------- Livreurs indépendants ----------
  /// Inscriptions ouvertes ? service actif ? livreurs en ligne
  Future<Map<String, dynamic>> independentsInfo() async =>
      (await _request('GET', '/independents/public')) as Map<String, dynamic>;

  Future<void> registerIndependent(
    String name,
    String phone,
    String password,
  ) async {
    await _saveSession(
      _request('POST', '/independents/register', {
        'name': name,
        'phone': phone,
        'password': password,
      }),
    );
    user = await _request('GET', '/auth/me');
  }

  Future<Map<String, dynamic>> myDossier() async =>
      (await _request('GET', '/independents/me')) as Map<String, dynamic>;
  Future<Map<String, dynamic>> saveDossier(Map<String, dynamic> body) async =>
      (await _request('PUT', '/independents/me', body)) as Map<String, dynamic>;
  Future<Map<String, dynamic>> submitDossier() async =>
      (await _request('POST', '/independents/me/submit'))
          as Map<String, dynamic>;

  /// Solde prépayé du livreur indépendant (commission prélevée à chaque course)
  Future<Map<String, dynamic>> myBalance() async =>
      (await _request('GET', '/billing/me')) as Map<String, dynamic>;
  Future<dynamic> requestTopup(Map<String, dynamic> body) =>
      _request('POST', '/billing/me/payments', {'kind': 'TOPUP', ...body});

  // ---------- Carnet du livreur ----------
  /// Livraisons saisies par le livreur (depuis [from], 90 jours par défaut)
  Future<List<dynamic>> logbook({DateTime? from}) async => await _request(
    'GET',
    '/logbook/me${from == null ? '' : '?from=${Uri.encodeComponent(from.toUtc().toIso8601String())}'}',
  );
  Future<Map<String, dynamic>> addLogbookEntry(
    Map<String, dynamic> body,
  ) async => (await _request('POST', '/logbook', body)) as Map<String, dynamic>;

  /// Plusieurs destinataires d'un coup (même photo, même note)
  Future<List<dynamic>> addLogbookEntries(Map<String, dynamic> body) async =>
      (await _request('POST', '/logbook/many', body)) as List<dynamic>;

  /// Ordre de passage choisi par le livreur (liste vide = le plus proche d'abord)
  Future<void> setLogbookOrder(List<String> ids) async =>
      await _request('POST', '/logbook/order', {'ids': ids});
  Future<Map<String, dynamic>> updateLogbookEntry(
    String id,
    Map<String, dynamic> body,
  ) async =>
      (await _request('PATCH', '/logbook/$id', body)) as Map<String, dynamic>;
  Future<Map<String, dynamic>> setLogbookStatus(
    String id,
    String status, {
    String? note,
  }) async =>
      (await _request('POST', '/logbook/$id/status', {
            'status': status,
            'note': ?note,
          }))
          as Map<String, dynamic>;

  /// Gains, part du livreur, reste à verser et historique des versements
  Future<Map<String, dynamic>> myCash() async =>
      (await _request('GET', '/remittances/me')) as Map<String, dynamic>;

  /// Déclare un versement à l'entreprise (elle confirme à réception)
  Future<dynamic> declareRemittance({
    required int amount,
    required String method,
    String? reference,
    String? proofUrl,
    String? note,
  }) => _request('POST', '/remittances/me', {
    'amount': amount,
    'method': method,
    'reference': ?reference,
    'proofUrl': ?proofUrl,
    'note': ?note,
  });

  /// Refuser une course affectée par l'entreprise
  Future<dynamic> declineAssignment(String id, {String? reason}) => _request(
    'POST',
    '/deliveries/$id/decline-assignment',
    {'reason': ?reason},
  );

  /// Colis non livrés rapportés à l'expéditeur (code de retour)
  Future<dynamic> confirmReturn(String id, String code) =>
      _request('POST', '/deliveries/$id/return', {'code': code});

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
