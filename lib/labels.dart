export 'countries.dart' show currencyLabel, formatMoney, formatPhone, telUri;
export 'vehicles.dart'
    show
        Vehicles,
        VehicleType,
        vehicleName,
        vehicleIcon,
        vehicleIconKind,
        vehicleDuotoneIcon;

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
  'FAILED': 'Non livré',
  'CANCELLED': 'Annulé',
};

const failureLabels = {
  'ABSENT': 'Destinataire absent',
  'REFUSED': 'Colis refusé',
  'WRONG_ADDRESS': 'Adresse introuvable',
  'NO_MONEY': 'Pas l’argent pour payer',
  'DAMAGED': 'Colis abîmé',
  'UNSAFE': 'Lieu dangereux ou inaccessible',
};

/// Suite d'un échec
const followUpLabels = {
  'DECIDING': 'En attente du choix de l’expéditeur',
  'RETRY': 'Nouvelle tentative',
  'RETURN': 'À rapporter à l’expéditeur',
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
