import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:live_activities/live_activities.dart';

import 'notifications.dart';

/// Groupe d'apps partagé avec l'extension Live Activity (Xcode : App Groups)
const kAppGroup = 'group.ci.leto.leto';

/// Suivi d'une course en direct hors de l'app :
/// - iPhone : Live Activity (écran verrouillé et Dynamic Island) ;
/// - Android : notification fixe avec barre de progression.
/// Mise à jour par l'app à chaque événement temps réel ; le compte à rebours de l'heure
/// d'arrivée continue de tourner même quand l'app est en pause.
class DeliveryLive {
  DeliveryLive._();
  static final instance = DeliveryLive._();

  final _ios = LiveActivities();
  final _local = FlutterLocalNotificationsPlugin();
  bool _iosReady = false;
  String? _current; // course affichée
  String? _lastKey; // évite les mises à jour identiques
  String? _role;

  static const _androidId = 7001;
  static const _channel = AndroidNotificationChannel(
    'leto_live',
    'Course en direct',
    description: 'Suivi de la course en cours',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
  );

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> _initIOS() async {
    if (_iosReady) return;
    await _ios.init(
      appGroupId: kAppGroup,
      requestAndroidNotificationPermission: false,
    );
    _iosReady = true;
  }

  /// Met à jour le suivi depuis une course (statut, livreur, arrêts) ; l'arrête si elle est finie.
  /// [driver] : vue du livreur (prochaine adresse) ; sinon vue du client (livreur, arrivée).
  Future<void> sync(
    Map<String, dynamic>? d, {
    required bool driver,
    int? etaMin,
  }) async {
    if (!_supported) return;
    final status = d?['status'];
    if (d == null || (status != 'ACCEPTED' && status != 'PICKED_UP')) {
      if (_current != null && (d == null || d['id'] == _current)) await end();
      return;
    }
    final stops = ((d['stops'] as List?) ?? []).cast<Map>();
    final total = stops.where((s) => s['status'] != 'CANCELLED').length;
    final done = stops
        .where((s) => s['status'] == 'DELIVERED' || s['status'] == 'FAILED')
        .length;
    final next = stops.cast<Map?>().firstWhere(
      (s) => s?['status'] == 'PENDING',
      orElse: () => null,
    );
    final driverName = d['driver']?['name'] as String? ?? 'Votre livreur';
    final independent = d['company']?['independent'] == true;
    final picked = status == 'PICKED_UP';
    final title = driver
        ? (picked ? 'Livraison en cours' : 'Récupérer les colis')
        : (picked
              ? 'Vos colis sont en route'
              : 'Livreur en route vers le départ');
    final subtitle = driver
        ? (picked
              ? (next?['address'] as String? ?? 'Dernier arrêt')
              : (d['pickupAddress'] as String? ?? ''))
        : '$driverName${independent ? ' · livreur indépendant' : ''}';
    final etaEpoch = etaMin == null
        ? 0
        : DateTime.now()
                  .add(Duration(minutes: etaMin))
                  .millisecondsSinceEpoch ~/
              1000;
    final data = <String, dynamic>{
      'title': title,
      'subtitle': subtitle,
      'status': status,
      'done': done,
      'total': total,
      'etaMin': etaMin ?? -1,
      'etaEpoch': etaEpoch,
      'role': driver ? 'driver' : 'client',
    };
    // Mise à jour seulement si quelque chose a changé (l'heure d'arrivée à la minute près)
    final key = '${d['id']}|$title|$subtitle|$done/$total|${etaMin ?? -1}';
    if (key == _lastKey) return;
    _lastKey = key;
    final id = d['id'] as String;
    if (_current != null && _current != id) await end();
    _current = id;
    _role = driver ? 'driver' : 'client';
    // Client : l'app reste connectée pendant la course (Android) pour suivre chaque étape
    if (!driver) {
      LetoNotifier.instance.startKeepAlive(
        driver: false,
        text: '$title · $subtitle',
      );
    }
    try {
      if (Platform.isIOS) {
        await _initIOS();
        if (!await _ios.areActivitiesEnabled()) return;
        await _ios.createOrUpdateActivity(
          id,
          data,
          iOSEnableRemoteUpdates: false,
        );
      } else {
        await _local
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(_channel);
        await _local.show(
          id: _androidId,
          title: title,
          body: [
            subtitle,
            if (total > 1) '$done/$total arrêts',
            if (etaMin != null) 'arrivée ~$etaMin min',
          ].where((x) => x.isNotEmpty).join(' · '),
          payload: id,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channel.id,
              _channel.name,
              channelDescription: _channel.description,
              importance: Importance.low,
              priority: Priority.low,
              ongoing: true,
              autoCancel: false,
              onlyAlertOnce: true,
              playSound: false,
              showProgress: total > 0,
              maxProgress: total == 0 ? 1 : total,
              progress: done,
              category: AndroidNotificationCategory.progress,
              visibility: NotificationVisibility.public,
              usesChronometer: false,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Suivi en direct : $e');
    }
  }

  Future<void> end() async {
    final id = _current;
    final role = _role;
    _current = null;
    _lastKey = null;
    _role = null;
    if (!_supported) return;
    if (role == 'client') LetoNotifier.instance.stopKeepAlive();
    try {
      if (Platform.isIOS) {
        if (id != null && _iosReady) await _ios.endActivity(id);
      } else {
        await _local.cancel(id: _androidId);
      }
    } catch (_) {}
  }
}
