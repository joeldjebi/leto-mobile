import 'package:phosphor_flutter/phosphor_flutter.dart';

export 'countries.dart' show currencyLabel, formatMoney, formatPhone, telUri;

/// Libellés et icônes partagés (offres, délais, paiements, statuts)

const statusLabels = {
  'PENDING': 'En attente',
  'ACCEPTED': 'Acceptée',
  'PICKED_UP': 'En cours',
  'DELIVERED': 'Terminée',
  'CANCELLED': 'Annulée',
};

const stopStatusLabels = {
  'PENDING': 'À livrer',
  'DELIVERED': 'Livré',
  'FAILED': 'Échec',
  'CANCELLED': 'Annulé',
};

const failureLabels = {
  'ABSENT': 'Destinataire absent',
  'REFUSED': 'Colis refusé',
};

const vehicleLabels = {'MOTO': 'Moto', 'CAR': 'Voiture', 'CARGO': 'Cargo'};

const vehicleIcons = {
  'MOTO': PhosphorIconsFill.moped,
  'CAR': PhosphorIconsBold.car,
  'CARGO': PhosphorIconsFill.package,
};

const speedLabels = {
  'EXPRESS': 'Express',
  'STANDARD': 'Standard',
  'SCHEDULED': 'Dans 2 heures',
};

String km(num d) => d < 1
    ? '${(d * 1000).round()} m'
    : '${d.toStringAsFixed(1).replaceAll('.', ',')} km';

/// « À l'instant », « 52 sec. », « 12 min. », « 2 h »
String timeAgo(String iso) {
  final s = DateTime.now().difference(DateTime.parse(iso)).inSeconds;
  if (s < 15) return 'À l’instant';
  if (s < 60) return '$s sec.';
  if (s < 3600) return '${s ~/ 60} min.';
  return '${s ~/ 3600} h';
}

/// Facteurs du prix d'un devis : majorations (pluie, heure de pointe…) et réduction tournée
String priceFactors(Map<String, dynamic>? quote) {
  if (quote == null) return '';
  final parts = <String>[
    for (final s in (quote['surcharges'] as List?) ?? const [])
      '${s['label']} +${s['pct']} %',
    if (((quote['stopDiscountPct'] as num?) ?? 0) > 0)
      'Tournée −${quote['stopDiscountPct']} %',
  ];
  return parts.join(' · ');
}
