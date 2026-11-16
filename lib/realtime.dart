import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api.dart';

/// Connexion temps réel (Socket.IO) partagée par toute l'app.
///
/// Événements reçus : `driver:location`, `delivery:updated`, `deliveries:changed`.
/// Événements envoyés : `driver:location`, `delivery:watch`, `delivery:unwatch`.
class Realtime {
  Realtime._();
  static final instance = Realtime._();

  io.Socket? _socket;

  io.Socket get socket => _socket ??= io.io(
    apiUrl,
    io.OptionBuilder()
        .setTransports(['websocket'])
        .setAuth({'token': Api.instance.token})
        .enableReconnection()
        .build(),
  );

  /// Exécute [action] maintenant si connecté, et à chaque (re)connexion.
  /// Renvoie une fonction pour se désabonner.
  void Function() onConnected(void Function() action) {
    final s = socket;
    void handler(_) => action();
    s.on('connect', handler);
    if (s.connected) action();
    return () => s.off('connect', handler);
  }

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}
