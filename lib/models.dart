import 'package:flutter/foundation.dart';
import 'api.dart';

/// Arrêt en cours de saisie (côté client), avant la création de la course
class StopDraft {
  Place place;
  String name;
  String phone;
  String details;
  String description = '';
  int cod = 0;
  String? photo;

  StopDraft(this.place, {this.name = '', this.phone = '', this.details = ''});

  /// Depuis une entrée du carnet d'adresses
  factory StopDraft.fromSaved(Map<String, dynamic> a) => StopDraft(
    Place.fromJson({
      'label': a['address'],
      'sublabel': a['recipientName'],
      'lat': a['lat'],
      'lng': a['lng'],
    }),
    name: a['recipientName'] ?? '',
    phone: a['recipientPhone'] ?? '',
    details: a['details'] ?? '',
  );
}

/// « Répéter » une course terminée : l'accueil client reprend son départ et ses destinataires
final repeatOrder = ValueNotifier<Map<String, dynamic>?>(null);
