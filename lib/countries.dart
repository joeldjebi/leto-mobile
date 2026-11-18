import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show apiUrl;

/// Pays géré par l'admin : indicatif, format des numéros, devise.
class Country {
  final String iso;
  final String name;
  final String flag;

  /// Indicatif sans « + » (225)
  final String dialCode;

  /// Chiffres après l'indicatif (10 en Côte d'Ivoire)
  final int phoneLength;

  /// Préfixe national retiré à l'international (« 0 » au Ghana, vide en Côte d'Ivoire)
  final String trunkPrefix;

  /// Exemple au format local ; ses espaces donnent le groupement d'affichage
  final String phoneExample;
  final String currencyCode;
  final String currencySymbol;
  final String currencyName;
  final int currencyDecimals;
  final bool operating;
  final int sortOrder;

  const Country({
    required this.iso,
    required this.name,
    this.flag = '',
    required this.dialCode,
    required this.phoneLength,
    this.trunkPrefix = '',
    this.phoneExample = '',
    required this.currencyCode,
    required this.currencySymbol,
    this.currencyName = '',
    this.currencyDecimals = 0,
    this.operating = false,
    this.sortOrder = 0,
  });

  /// Repli hors ligne (aucune liste en cache)
  static const ci = Country(
    iso: 'CI',
    name: 'Côte d’Ivoire',
    flag: '🇨🇮',
    dialCode: '225',
    phoneLength: 10,
    phoneExample: '07 01 02 03 04',
    currencyCode: 'XOF',
    currencySymbol: 'F',
    currencyName: 'Franc CFA (BCEAO)',
    operating: true,
    sortOrder: 1,
  );

  factory Country.fromJson(Map<String, dynamic> j) {
    final iso = (j['iso'] ?? '').toString().toUpperCase();
    final flag = (j['flag'] ?? '').toString();
    return Country(
      iso: iso,
      name: (j['name'] ?? iso).toString(),
      flag: flag.isNotEmpty ? flag : flagOf(iso),
      dialCode: (j['dialCode'] ?? '').toString(),
      phoneLength: (j['phoneLength'] as num?)?.toInt() ?? 0,
      trunkPrefix: (j['trunkPrefix'] ?? '').toString(),
      phoneExample: (j['phoneExample'] ?? '').toString(),
      currencyCode: (j['currencyCode'] ?? '').toString().toUpperCase(),
      currencySymbol: (j['currencySymbol'] ?? '').toString(),
      currencyName: (j['currencyName'] ?? '').toString(),
      currencyDecimals: (j['currencyDecimals'] as num?)?.toInt() ?? 0,
      operating: j['operating'] == true,
      sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'iso': iso,
    'name': name,
    'flag': flag,
    'dialCode': dialCode,
    'phoneLength': phoneLength,
    'trunkPrefix': trunkPrefix,
    'phoneExample': phoneExample,
    'currencyCode': currencyCode,
    'currencySymbol': currencySymbol,
    'currencyName': currencyName,
    'currencyDecimals': currencyDecimals,
    'active': true,
    'operating': operating,
    'sortOrder': sortOrder,
  };

  /// Groupes de chiffres du numéro national (sans préfixe), tirés de l'exemple, sinon par paires
  List<int> get nationalGroups {
    final groups = phoneExample
        .trim()
        .split(RegExp(r'\s+'))
        .map((g) => g.replaceAll(RegExp(r'\D'), '').length)
        .where((n) => n > 0)
        .toList();
    var total = groups.fold<int>(0, (a, b) => a + b);
    final exampleDigits = phoneExample.replaceAll(RegExp(r'\D'), '');
    if (trunkPrefix.isNotEmpty &&
        groups.isNotEmpty &&
        total == phoneLength + trunkPrefix.length &&
        exampleDigits.startsWith(trunkPrefix)) {
      groups[0] -= trunkPrefix.length;
      if (groups[0] <= 0) groups.removeAt(0);
      total -= trunkPrefix.length;
    }
    if (groups.isNotEmpty && total == phoneLength) return groups;
    return [
      for (var i = 0; i < phoneLength; i += 2) phoneLength - i >= 2 ? 2 : 1,
    ];
  }

  @override
  bool operator ==(Object other) => other is Country && other.iso == iso;
  @override
  int get hashCode => iso.hashCode;
  @override
  String toString() => 'Country($iso +$dialCode)';
}

/// Drapeau emoji à partir du code ISO (CI → 🇨🇮)
String flagOf(String iso) => iso.length != 2
    ? ''
    : String.fromCharCodes(
        iso.toUpperCase().codeUnits.map((c) => 0x1f1e6 + c - 65),
      );

/// Registre des pays actifs (GET /countries), en cache pour le hors ligne.
class Countries extends ChangeNotifier {
  Countries._();
  static final instance = Countries._();

  static const _prefsKey = 'countries';

  List<Country> _list = const [Country.ci];
  String _operatingIso = 'CI';

  /// Pays actifs, dans l'ordre choisi par l'admin
  List<Country> get list => _list;

  /// Pays où LETO livre (devise par défaut, numéros locaux)
  Country get operating =>
      byIso(_operatingIso) ??
      _list.where((c) => c.operating).firstOrNull ??
      (_list.isNotEmpty ? _list.first : Country.ci);

  Country? byIso(String? iso) =>
      _list.where((c) => c.iso == iso?.toUpperCase()).firstOrNull;

  Country? byCurrency(String? code) =>
      _list.where((c) => c.currencyCode == code?.toUpperCase()).firstOrNull;

  /// Pays d'un numéro E.164 (indicatif le plus long d'abord)
  Country? byE164(String? e164) {
    if (e164 == null || !e164.startsWith('+')) return null;
    final rest = e164.substring(1);
    final sorted = [..._list]
      ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
    for (final c in sorted) {
      if (c.dialCode.isNotEmpty &&
          rest.startsWith(c.dialCode) &&
          rest.length == c.dialCode.length + c.phoneLength) {
        return c;
      }
    }
    return null;
  }

  /// Démarrage : cache local puis API (sans bloquer)
  Future<void> init() async {
    await restore();
    await load();
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) _apply(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Recharge la liste (démarrage, `countries:changed`)
  Future<void> load() async {
    try {
      final res = await http
          .get(Uri.parse('$apiUrl/countries'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map<String, dynamic> || !_apply(data)) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (_) {
      // Hors ligne : on garde la liste actuelle
    }
  }

  bool _apply(Map<String, dynamic> data) {
    final list = [
      for (final c in (data['countries'] as List? ?? const []))
        if (c is Map) Country.fromJson(Map<String, dynamic>.from(c)),
    ].where((c) => c.dialCode.isNotEmpty && c.phoneLength > 0).toList();
    if (list.isEmpty) return false;
    list.sort((a, b) {
      final o = a.sortOrder.compareTo(b.sortOrder);
      return o != 0 ? o : a.name.compareTo(b.name);
    });
    _list = List.unmodifiable(list);
    _operatingIso =
        (data['operating'] as String?) ??
        list.where((c) => c.operating).firstOrNull?.iso ??
        list.first.iso;
    notifyListeners();
    return true;
  }

  /// Tests : liste imposée
  @visibleForTesting
  void setForTest(List<Country> list, {String? operating}) {
    _list = List.unmodifiable(list);
    _operatingIso =
        operating ??
        list.where((c) => c.operating).firstOrNull?.iso ??
        (list.isNotEmpty ? list.first.iso : 'CI');
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Numéros de téléphone
// ---------------------------------------------------------------------------

String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

/// Chiffres nationaux saisis (préfixe national retiré s'il a été tapé)
String nationalDigits(Country c, String input) {
  var d = _digits(input);
  if (c.trunkPrefix.isNotEmpty &&
      d.length == c.phoneLength + c.trunkPrefix.length &&
      d.startsWith(c.trunkPrefix)) {
    d = d.substring(c.trunkPrefix.length);
  }
  return d;
}

/// « +2250701020304 » à partir d'une saisie locale ; null si invalide
String? toE164(Country c, String input) {
  final d = nationalDigits(c, input);
  return d.length == c.phoneLength ? '+${c.dialCode}$d' : null;
}

/// Message d'erreur en français, ou null si le numéro est valide
String? validatePhone(Country c, String? input, {bool required = true}) {
  final s = (input ?? '').trim();
  if (s.isEmpty) return required ? 'Indiquez le numéro de téléphone' : null;
  if (RegExp(r'[^\d\s.\-()/]').hasMatch(s)) {
    return 'Le numéro ne doit contenir que des chiffres';
  }
  if (toE164(c, s) != null) return null;
  final example = c.phoneExample.isEmpty ? '' : ' (ex. ${c.phoneExample})';
  return 'Numéro invalide : ${c.phoneLength} chiffres attendus$example';
}

/// Numéro du répertoire ou ancien format → E.164 :
/// « +225 07… », « 00225… », « 225… » (longueur complète), ou local (pays où LETO livre).
/// Null si le numéro ne correspond à aucun pays actif.
String? parseAnyPhone(String? raw) {
  if (raw == null) return null;
  var s = raw.trim().replaceAll(RegExp(r'[\s.\-()/ ]'), '');
  if (s.isEmpty) return null;
  if (s.startsWith('00')) s = '+${s.substring(2)}';
  final reg = Countries.instance;
  if (s.startsWith('+')) {
    final rest = s.substring(1);
    if (!RegExp(r'^\d+$').hasMatch(rest)) return null;
    final sorted = [...reg.list]
      ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
    for (final c in sorted) {
      if (rest.startsWith(c.dialCode)) {
        final r = toE164(c, rest.substring(c.dialCode.length));
        if (r != null) return r;
      }
    }
    return null;
  }
  if (!RegExp(r'^\d+$').hasMatch(s)) return null;
  final local = toE164(reg.operating, s);
  if (local != null) return local;
  for (final c in reg.list) {
    if (s.startsWith(c.dialCode) &&
        s.length == c.dialCode.length + c.phoneLength) {
      return '+$s';
    }
  }
  return null;
}

/// Deux numéros identiques une fois normalisés (E.164)
bool samePhone(String? a, String? b) {
  final x = parseAnyPhone(a) ?? a?.trim();
  final y = parseAnyPhone(b) ?? b?.trim();
  return x != null && x.isNotEmpty && x == y;
}

String _group(String digits, List<int> groups) {
  final parts = <String>[];
  var i = 0;
  for (final g in groups) {
    if (i >= digits.length) break;
    final end = (i + g).clamp(0, digits.length);
    parts.add(digits.substring(i, end));
    i = end;
  }
  if (i < digits.length) parts.add(digits.substring(i));
  return parts.join(' ');
}

/// Affichage : « 🇨🇮 +225 07 01 02 03 04 ».
/// [compact] : numéro du pays où LETO livre au format local (« 07 01 02 03 04 »).
/// Valeur inconnue : renvoyée telle quelle.
String formatPhone(String? value, {bool flag = true, bool compact = false}) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return '';
  final e164 = raw.startsWith('+') ? raw : parseAnyPhone(raw);
  final reg = Countries.instance;
  final c = reg.byE164(e164);
  if (e164 == null || c == null) return raw;
  final national = e164.substring(1 + c.dialCode.length);
  if (compact && c == reg.operating) {
    final example = c.phoneExample.trim();
    final groups = example
        .split(RegExp(r'\s+'))
        .map((g) => _digits(g).length)
        .where((n) => n > 0)
        .toList();
    final local = '${c.trunkPrefix}$national';
    if (groups.fold<int>(0, (a, b) => a + b) == local.length) {
      return _group(local, groups);
    }
    return _group(national, c.nationalGroups);
  }
  final text = '+${c.dialCode} ${_group(national, c.nationalGroups)}';
  return flag && c.flag.isNotEmpty ? '${c.flag} $text' : text;
}

/// Lien `tel:` (E.164 si le numéro est reconnu)
Uri telUri(String? phone) =>
    Uri(scheme: 'tel', path: parseAnyPhone(phone) ?? (phone ?? '').trim());

// ---------------------------------------------------------------------------
// Montants
// ---------------------------------------------------------------------------

/// « 1 500 F » : devise [currencyCode] (celle d'une course ou du carnet),
/// sinon celle du pays où LETO livre.
String formatMoney(Object? amount, [String? currencyCode]) {
  final reg = Countries.instance;
  final c = reg.byCurrency(currencyCode) ?? reg.operating;
  final n = switch (amount) {
    num v => v,
    String v => num.tryParse(v.replaceAll(' ', '').replaceAll(',', '.')) ?? 0,
    _ => 0,
  };
  final decimals = c.currencyDecimals.clamp(0, 3);
  final negative = n < 0;
  final abs = n.abs();
  String intPart;
  var frac = '';
  if (decimals == 0) {
    intPart = abs.toInt().toString();
  } else {
    final fixed = abs.toStringAsFixed(decimals);
    final dot = fixed.indexOf('.');
    intPart = fixed.substring(0, dot);
    final f = fixed.substring(dot + 1);
    // Montant rond : pas de décimales (« 1 500 ₵ ») ; sinon toutes (« 12,50 ₵ »)
    if (f.replaceAll('0', '').isNotEmpty) frac = ',$f';
  }
  final grouped = intPart.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ' ',
  );
  return '${negative ? '-' : ''}$grouped$frac ${c.currencySymbol}';
}

/// Nom court de la devise pour les libellés de saisie (« F CFA », « ₵ »)
String currencyLabel([String? currencyCode]) {
  final reg = Countries.instance;
  final c = reg.byCurrency(currencyCode) ?? reg.operating;
  return c.currencyCode == 'XOF' ? 'F CFA' : c.currencySymbol;
}
