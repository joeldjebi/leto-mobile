import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show apiUrl;

/// Type d'engin du catalogue géré par le Super Admin (GET /pricing/vehicles)
class VehicleType {
  /// Code stable : MOTO, CAR, CARGO, VELO, TRICYCLE…
  final String code;

  /// Nom court affiché (« Vélo »)
  final String name;
  final String label;

  /// Pictogramme : moto | bike | tricycle | car | van | truck
  final String icon;
  final String description;
  final bool enabled;

  const VehicleType({
    required this.code,
    required this.name,
    this.label = '',
    this.icon = 'moto',
    this.description = '',
    this.enabled = true,
  });

  factory VehicleType.fromJson(Map<String, dynamic> j) {
    final code = (j['code'] ?? '').toString();
    final name = (j['name'] ?? '').toString();
    final label = (j['label'] ?? '').toString();
    return VehicleType(
      code: code,
      name: name.isNotEmpty ? name : (label.isNotEmpty ? label : code),
      label: label,
      icon: (j['icon'] ?? 'moto').toString(),
      description: (j['description'] ?? '').toString(),
      enabled: j['enabled'] != false,
    );
  }

  /// Repli hors ligne (aucun catalogue en cache)
  static const defaults = [
    VehicleType(code: 'MOTO', name: 'Moto', icon: 'moto'),
    VehicleType(code: 'CAR', name: 'Voiture', icon: 'car'),
    VehicleType(code: 'CARGO', name: 'Cargo', icon: 'truck'),
  ];
}

/// Catalogue des engins, en cache pour l'affichage hors ligne.
class Vehicles extends ChangeNotifier {
  Vehicles._();
  static final instance = Vehicles._();

  static const _prefsKey = 'vehicles';

  List<VehicleType> _list = VehicleType.defaults;

  /// Tous les engins connus (y compris désactivés : courses passées)
  List<VehicleType> get list => _list;

  /// Engins proposés aujourd'hui
  List<VehicleType> get enabled => _list.where((v) => v.enabled).toList();

  VehicleType? byCode(String? code) =>
      code == null ? null : _list.where((v) => v.code == code).firstOrNull;

  /// Démarrage : cache local puis API (sans bloquer)
  Future<void> init() async {
    await restore();
    await load();
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) _apply(jsonDecode(raw));
    } catch (_) {}
  }

  Future<void> load() async {
    try {
      final res = await http
          .get(Uri.parse('$apiUrl/pricing/vehicles'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (!_apply(data)) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (_) {
      // Hors ligne : on garde le catalogue actuel
    }
  }

  bool _apply(dynamic data) {
    if (data is! List) return false;
    final list = [
      for (final v in data)
        if (v is Map) VehicleType.fromJson(Map<String, dynamic>.from(v)),
    ].where((v) => v.code.isNotEmpty).toList();
    if (list.isEmpty) return false;
    _list = List.unmodifiable(list);
    notifyListeners();
    return true;
  }

  /// Tests : catalogue imposé
  @visibleForTesting
  void setForTest(List<VehicleType> list) {
    _list = List.unmodifiable(list);
    notifyListeners();
  }
}

/// Nom de l'engin (« Vélo ») ; à défaut [fallback] (nom renvoyé par l'API), puis le code
String vehicleName(String? code, {String? fallback}) =>
    Vehicles.instance.byCode(code)?.name ??
    (fallback != null && fallback.isNotEmpty ? fallback : (code ?? ''));

/// Pictogramme de l'engin (moto si inconnu) ; [hint] = pictogramme renvoyé par l'API
String vehicleIconKind(String? code, {String? hint}) =>
    Vehicles.instance.byCode(code)?.icon ?? hint ?? 'moto';

/// Icône de l'engin (listes, fiches, offres)
IconData vehicleIcon(String? code, {String? hint}) =>
    switch (vehicleIconKind(code, hint: hint)) {
      'car' => PhosphorIconsBold.car,
      'truck' => PhosphorIconsFill.package,
      'bike' => PhosphorIconsFill.bicycle,
      'tricycle' => PhosphorIconsFill.scooter,
      'van' => PhosphorIconsFill.van,
      _ => PhosphorIconsFill.moped,
    };

/// Icône de l'engin sur la carte (pastille du livreur)
IconData vehicleMarkerIcon(String? code) => switch (vehicleIconKind(code)) {
  'car' => PhosphorIconsFill.carProfile,
  'truck' => PhosphorIconsFill.truck,
  'bike' => PhosphorIconsFill.bicycle,
  'tricycle' => PhosphorIconsFill.scooter,
  'van' => PhosphorIconsFill.van,
  _ => PhosphorIconsFill.motorcycle,
};

/// Icône d'offre en deux tons (carrousel du client)
PhosphorIconData vehicleDuotoneIcon(String? code, {String? hint}) =>
    switch (vehicleIconKind(code, hint: hint)) {
      'car' => PhosphorIcons.car(PhosphorIconsStyle.duotone),
      'truck' => PhosphorIcons.truck(PhosphorIconsStyle.duotone),
      'bike' => PhosphorIcons.bicycle(PhosphorIconsStyle.duotone),
      'tricycle' => PhosphorIcons.scooter(PhosphorIconsStyle.duotone),
      'van' => PhosphorIcons.van(PhosphorIconsStyle.duotone),
      _ => PhosphorIcons.moped(PhosphorIconsStyle.duotone),
    };
