import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// URL de l'API. Surchargeable : flutter run --dart-define=API_URL=http://192.168.1.10:3000
/// Par défaut : 10.0.2.2 sur émulateur Android (= localhost du Mac), localhost sinon.
final String apiUrl = const String.fromEnvironment('API_URL').isNotEmpty
    ? const String.fromEnvironment('API_URL')
    : (Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000');

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

const statusLabels = {
  'PENDING': 'En attente',
  'ACCEPTED': 'Acceptée',
  'PICKED_UP': 'En cours',
  'DELIVERED': 'Livrée',
  'CANCELLED': 'Annulée',
};

String fcfa(num n) {
  final s = n.toInt().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ' ');
  return '$s FCFA';
}

class Api {
  Api._();
  static final instance = Api._();

  String? _token;
  Map<String, dynamic>? user;

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

  Future<void> login(String phone, String password) =>
      _saveSession(_request('POST', '/auth/login', {'phone': phone, 'password': password}));

  Future<void> register(String name, String phone, String password) => _saveSession(
      _request('POST', '/auth/register', {'name': name, 'phone': phone, 'password': password}));

  Future<void> logout() async {
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

  // ---------- Tarifs ----------
  Future<List<String>> communes() async =>
      List<String>.from(await _request('GET', '/pricing/communes'));

  Future<int> quote(String from, String to) async {
    final q = Uri(queryParameters: {'from': from, 'to': to}).query;
    return (await _request('GET', '/pricing/quote?$q'))['price'];
  }

  // ---------- Client ----------
  Future<List<dynamic>> myDeliveries() async => await _request('GET', '/deliveries/mine');
  Future<dynamic> createDelivery(Map<String, dynamic> body) =>
      _request('POST', '/deliveries', body);
  Future<Map<String, dynamic>> getDelivery(String id) async =>
      await _request('GET', '/deliveries/mine/$id');
  Future<dynamic> cancel(String id) => _request('POST', '/deliveries/$id/cancel');

  // ---------- Livreur ----------
  Future<List<dynamic>> available() async => await _request('GET', '/deliveries/available');
  Future<List<dynamic>> driverDeliveries() async => await _request('GET', '/deliveries/driver');
  Future<dynamic> accept(String id) => _request('POST', '/deliveries/$id/accept');
  Future<dynamic> pickup(String id) => _request('POST', '/deliveries/$id/pickup');
  Future<dynamic> deliver(String id, String code) =>
      _request('POST', '/deliveries/$id/deliver', {'code': code});

  Future<dynamic> _request(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$apiUrl$path'))
      ..headers['Content-Type'] = 'application/json';
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    if (body != null) req.body = jsonEncode(body);

    final http.Response res;
    try {
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 15)));
    } catch (_) {
      throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.');
    }
    final data = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final msg = data is Map ? data['message'] : null;
      throw ApiException(msg is List ? msg.join('\n') : (msg?.toString() ?? 'Erreur ${res.statusCode}'));
    }
    return data;
  }
}
