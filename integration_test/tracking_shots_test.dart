// Captures du suivi client (vraie app, vraie API locale). Le script hôte prend une capture à chaque ligne « SHOT:nom ».
// flutter test integration_test/tracking_shots_test.dart -d <simulateur> --dart-define=API_URL=local
//   --dart-define=DEV_PHONE=… --dart-define=DEV_PASSWORD=… --dart-define=ACCEPTED=<id> --dart-define=DELIVERED=<id>
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;
import 'package:leto/screens/tracking_screen.dart';

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

  testWidgets('suivi client', (t) async {
    app.main();
    await wait(t, 6);
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute(builder: (_) => const TrackingScreen(String.fromEnvironment('ACCEPTED'))));
    await wait(t, 6);
    shot('accepted');
    await wait(t, 2);
    // « Montrer au livreur où je me trouve »
    await t.tap(find.byType(CupertinoSwitch).first);
    await wait(t, 3);
    shot('sharing');
    await wait(t, 1);
    await t.drag(find.byType(SingleChildScrollView).last, const Offset(0, -500));
    await wait(t, 1.5);
    shot('accepted_bottom');
    await wait(t, 2);
    nav.pop();
    await wait(t, 1.5);
    nav.push(MaterialPageRoute(builder: (_) => const TrackingScreen(String.fromEnvironment('DELIVERED'))));
    await wait(t, 6);
    shot('delivered');
    await wait(t, 2);
    await t.tap(find.byIcon(CupertinoIcons.star).last);
    await wait(t, 1);
    await t.drag(find.byType(SingleChildScrollView).last, const Offset(0, -250));
    await wait(t, 1.5);
    shot('rating');
    await wait(t, 2);
    await t.tap(find.text('Détails'));
    await wait(t, 2);
    shot('details');
    await wait(t, 2);
  });
}
