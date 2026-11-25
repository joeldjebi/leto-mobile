// Captures : alerte plein écran « nouvelle course » chez un livreur déjà en course, puis 2 courses dans « En cours ».
// flutter test integration_test/order_alert_shots_test.dart -d <simulateur> --dart-define=API_URL=local
//   --dart-define=DEV_PHONE=<livreur> --dart-define=DEV_PASSWORD=… --dart-define=DEV_LAT=5.32 --dart-define=DEV_LNG=-4.02
//   --dart-define=SCREENSHOTS=true
// La commande est créée par le script hôte pendant que l'app attend (alerte reçue par le temps réel).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;

Future<void> wait(WidgetTester t, double seconds) async {
  for (var i = 0; i < seconds * 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void shot(String name) {
  // ignore: avoid_print
  print('SHOT:$name');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('livreur en course : alerte nouvelle course, acceptation', (t) async {
    app.main();
    await wait(t, 8);
    final alert = find.byKey(const Key('order-alert'));
    for (var i = 0; i < 180 && alert.evaluate().isEmpty; i++) {
      await wait(t, 0.5);
    }
    expect(alert, findsOneWidget, reason: 'alerte nouvelle course affichée');
    await wait(t, 1.5);
    shot('order_alert');
    await wait(t, 2);
    await t.tap(find.byKey(const Key('order-alert-accept')));
    await wait(t, 4);
    expect(alert, findsNothing);
    shot('active_two');
    await wait(t, 1);
    expect(find.byKey(const Key('active-switcher')), findsOneWidget);
  });
}
