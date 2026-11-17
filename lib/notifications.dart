import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'live_activity.dart';
import 'realtime.dart';

/// Les 3 sons LETO intégrés à l'app (assets/sounds/ID.wav)
const builtinSounds = ['leto_course', 'leto_affectation', 'leto_alerte'];

/// Notifications locales déclenchées par le temps réel (Socket.IO), sans service externe :
/// le serveur envoie `notify` (titre, texte, son) aux bonnes personnes ; l'app affiche la
/// notification et joue le son LETO choisi par l'admin.
///
/// Pour recevoir les notifications app en arrière-plan ou écran verrouillé, l'app doit rester en vie :
/// - Android : service au premier plan (livreur en ligne, ou client avec une course en cours) ;
/// - iPhone : localisation en arrière-plan (livreur en ligne).
class LetoNotifier {
  LetoNotifier._();
  static final instance = LetoNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _player = AudioPlayer();
  final _seen = <String>{};
  bool _ready = false;
  void Function()? _detach;

  /// Course ouverte en touchant une notification (lue par les écrans d'accueil)
  final tapped = ValueNotifier<String?>(null);

  /// Fichiers des sons ajoutés par l'admin (id → chemin local)
  final Map<String, String> _custom = {};

  static const _channel = AndroidNotificationChannel(
    'leto_events',
    'Courses LETO',
    description: 'Nouvelles courses, affectations, annulations et suivi',
    importance: Importance.max,
    // Le son LETO est joué par l'app (il peut être changé par l'admin)
    playSound: false,
  );

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    if (_ready || !_supported) return;
    _ready = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
            defaultPresentBanner: true,
            defaultPresentSound: true,
            defaultPresentList: true,
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          if ((r.payload ?? '').isNotEmpty) tapped.value = r.payload;
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);
      if (Platform.isIOS) await _installBuiltinSoundsIOS();
      if (Platform.isAndroid) {
        FlutterForegroundTask.initCommunicationPort();
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'leto_online',
            channelName: 'LETO en ligne',
            channelDescription:
                'Garde LETO connecté pour recevoir les courses en temps réel',
            onlyAlertOnce: true,
          ),
          iosNotificationOptions: const IOSNotificationOptions(
            showNotification: false,
            playSound: false,
          ),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            allowWakeLock: true,
            allowWifiLock: true,
          ),
        );
      }
    } catch (e) {
      debugPrint('Notifications indisponibles : $e');
    }
  }

  /// Demande l'autorisation d'afficher des notifications (à la connexion)
  Future<void> requestPermission() async {
    if (!_supported) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  /// Écoute le temps réel (après connexion) : notifications et changements de sons
  void attach() {
    if (!_supported || Api.instance.token == null) return;
    _detach?.call();
    final s = Realtime.instance.socket;
    void onNotify(dynamic data) {
      if (data is Map) show(Map<String, dynamic>.from(data));
    }

    void onSounds(dynamic _) => syncSounds();
    s.on('notify', onNotify);
    s.on('sounds:changed', onSounds);
    _detach = () {
      s.off('notify', onNotify);
      s.off('sounds:changed', onSounds);
    };
    syncSounds();
  }

  void detach() {
    _detach?.call();
    _detach = null;
    stopKeepAlive();
  }

  // ---------- Sons ----------

  /// Télécharge les sons ajoutés par l'admin (une seule fois par fichier)
  Future<void> syncSounds() async {
    try {
      final res = await Api.instance.notificationSounds();
      final dir = await _soundsDir();
      for (final s in (res['sounds'] as List).cast<Map>()) {
        final url = s['url'] as String?;
        if (s['builtin'] == true || url == null) continue;
        final file = File('${dir.path}/${s['id']}.wav');
        if (!await file.exists()) {
          final r = await http.get(Uri.parse(photoUrl(url)));
          if (r.statusCode != 200) continue;
          await file.writeAsBytes(r.bodyBytes);
        }
        _custom[s['id'] as String] = file.path;
      }
    } catch (e) {
      debugPrint('Sons LETO : $e');
    }
  }

  /// iPhone : les sons de notification doivent être dans Library/Sounds
  Future<Directory> _soundsDir() async {
    final base = Platform.isIOS
        ? await getLibraryDirectory()
        : await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}/${Platform.isIOS ? 'Sounds' : 'sounds'}',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _installBuiltinSoundsIOS() async {
    final dir = await _soundsDir();
    for (final id in builtinSounds) {
      final f = File('${dir.path}/$id.wav');
      if (await f.exists()) continue;
      final data = await rootBundle.load('assets/sounds/$id.wav');
      await f.writeAsBytes(data.buffer.asUint8List());
    }
  }

  /// Joue un son LETO (aperçu ou notification sur Android)
  Future<void> play(String soundId) async {
    try {
      await _player.stop();
      final custom = _custom[soundId];
      if (custom != null) {
        await _player.play(DeviceFileSource(custom));
      } else {
        final id = builtinSounds.contains(soundId)
            ? soundId
            : builtinSounds.first;
        await _player.play(AssetSource('sounds/$id.wav'));
      }
    } catch (e) {
      debugPrint('Lecture du son : $e');
    }
  }

  // ---------- Affichage ----------

  Future<void> show(Map<String, dynamic> p) async {
    final id = (p['id'] ?? '${p['type']}${p['deliveryId']}') as String;
    if (!_seen.add(id)) return; // déjà affichée (reconnexion)
    final soundId = (p['sound']?['id'] as String?) ?? builtinSounds.first;
    final iosSound =
        _custom.containsKey(soundId) || builtinSounds.contains(soundId)
        ? '$soundId.wav'
        : '${builtinSounds.first}.wav';
    try {
      if (Platform.isAndroid) unawaited(play(soundId));
      await _plugin.show(
        id: id.hashCode & 0x7fffffff,
        title: p['title'] as String?,
        body: p['body'] as String?,
        payload: p['deliveryId'] as String?,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.max,
            priority: Priority.high,
            playSound: false,
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
          ),
          iOS: DarwinNotificationDetails(
            sound: iosSound,
            presentSound: true,
            presentBanner: true,
            interruptionLevel:
                p['type'] == 'NEW_ORDER' || p['type'] == 'ASSIGNED'
                ? InterruptionLevel.timeSensitive
                : InterruptionLevel.active,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Notification : $e');
    }
    // Client : le suivi en direct (Live Activity / notification fixe) suit chaque étape
    final deliveryId = p['deliveryId'] as String?;
    if (Api.instance.role == 'CLIENT' && deliveryId != null) {
      try {
        final d = await Api.instance.getDelivery(deliveryId);
        await DeliveryLive.instance.sync(
          (d as Map).cast<String, dynamic>(),
          driver: false,
        );
      } catch (_) {}
    }
  }

  // ---------- Rester connecté en arrière-plan (Android) ----------

  /// Android : service au premier plan qui garde l'app (et sa connexion) en vie.
  /// [driver] : livreur en ligne (type « localisation ») ; sinon client avec une course en cours.
  Future<void> startKeepAlive({required bool driver, String? text}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final title = driver ? 'LETO · en ligne' : 'LETO · course en cours';
      final body =
          text ??
          (driver
              ? 'Vous recevez les courses en temps réel'
              : 'Suivi de votre livraison en direct');
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: body,
        );
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 4242,
        serviceTypes: [
          driver
              ? ForegroundServiceTypes.location
              : ForegroundServiceTypes.dataSync,
        ],
        notificationTitle: title,
        notificationText: body,
        callback: keepAliveCallback,
      );
    } catch (e) {
      debugPrint('Service au premier plan : $e');
    }
  }

  Future<void> stopKeepAlive() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}

/// Point d'entrée du service au premier plan : il ne fait rien d'autre que garder l'app en vie
@pragma('vm:entry-point')
void keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
