// Suivi en direct côté client pendant que le livreur roule (script hôte), captures « SHOT:nom ».
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('suivi en direct', (t) async {
    app.main();
    await wait(t, 6);
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute(builder: (_) => const TrackingScreen(String.fromEnvironment('ACCEPTED'))));
    // ignore: avoid_print
    print('READY');
    await wait(t, 12);
    // ignore: avoid_print
    print('SHOT:live1');
    await wait(t, 20);
    // ignore: avoid_print
    print('SHOT:live2');
    await wait(t, 2);
  });
}
