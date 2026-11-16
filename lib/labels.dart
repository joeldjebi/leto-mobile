import 'package:flutter/material.dart';

/// Libellés et icônes partagés (offres, délais, paiements, statuts)

const statusLabels = {
  'PENDING': 'En attente',
  'ACCEPTED': 'Acceptée',
  'PICKED_UP': 'En cours',
  'DELIVERED': 'Livrée',
  'CANCELLED': 'Annulée',
};

const vehicleLabels = {'MOTO': 'Moto', 'CAR': 'Voiture', 'CARGO': 'Cargo'};

const vehicleIcons = {
  'MOTO': Icons.two_wheeler,
  'CAR': Icons.directions_car_filled,
  'CARGO': Icons.local_shipping,
};

const speedLabels = {
  'EXPRESS': 'Express',
  'STANDARD': 'Standard',
  'SCHEDULED': 'Dans 2 heures',
};

const paymentLabels = {
  'CASH': 'Espèces',
  'WAVE': 'Wave',
  'ORANGE_MONEY': 'Orange Money',
  'MTN_MOMO': 'MTN MoMo',
};

/// Couleurs des badges de paiement (fond, texte)
const paymentColors = {
  'CASH': (Color(0xFFE8F5E9), Color(0xFF1B5E20)),
  'WAVE': (Color(0xFFD7F5FF), Color(0xFF0B6E99)),
  'ORANGE_MONEY': (Color(0xFFFFE8D1), Color(0xFFB35400)),
  'MTN_MOMO': (Color(0xFFFFF4C2), Color(0xFF7A5D00)),
};

const paymentIcons = {
  'CASH': Icons.payments_outlined,
  'WAVE': Icons.waves,
  'ORANGE_MONEY': Icons.phone_android,
  'MTN_MOMO': Icons.phone_android,
};

String fcfa(num n) {
  final s = n.toInt().toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ' ',
  );
  return '$s F';
}

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
