// Captures côté livreur : course en cours avec la position partagée par le client (ligne « SHOT:nom »).
// flutter test integration_test/driver_shots_test.dart -d <simulateur> --dart-define=API_URL=local
//   --dart-define=DEV_PHONE=<livreur> --dart-define=DEV_PASSWORD=… --dart-define=DEV_LAT=… --dart-define=DEV_LNG=…
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;

Future<void> wait(WidgetTester t, double seconds) async {
  for (var i = 0; i < seconds * 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('livreur : position du client', (t) async {
    app.main();
    await wait(t, 8);
    final tab = find.textContaining('En cours');
    if (tab.evaluate().isNotEmpty) await t.tap(tab.first);
    await wait(t, 4);
    // ignore: avoid_print
    print('SHOT:driver_client');
    await wait(t, 2);
  });
}
