import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
  'MOTO': Icons.two_wheeler,
  'CAR': CupertinoIcons.car_detailed,
  'CARGO': CupertinoIcons.cube_box_fill,
};

const speedLabels = {
  'EXPRESS': 'Express',
  'STANDARD': 'Standard',
  'SCHEDULED': 'Dans 2 heures',
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
