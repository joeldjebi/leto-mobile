// Captures : « Ma tournée » d'un livreur avec plusieurs courses, puis « Plus tard » sur la première étape.
// flutter test integration_test/tour_shots_test.dart -d <simulateur> --dart-define=API_URL=local
//   --dart-define=DEV_PHONE=<livreur> --dart-define=DEV_PASSWORD=… --dart-define=DEV_LAT=5.32 --dart-define=DEV_LNG=-4.02
//   --dart-define=SCREENSHOTS=true
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

  testWidgets('livreur : tournée, Plus tard', (t) async {
    app.main();
    await wait(t, 8);
    await t.tap(find.textContaining('En cours').first);
    await wait(t, 3);
    final list = find.byKey(const Key('plan-list'));
    expect(list, findsOneWidget);
    // Panneau agrandi pour voir la tournée
    await t.drag(find.text('Ma tournée'), const Offset(0, -420));
    await wait(t, 2);
    shot('tour');
    final firstTitle = (t.widget<Text>(find.descendant(of: list, matching: find.byType(Text)).at(1))).data;
    await t.tap(find.byKey(const Key('plan-menu-0')));
    await wait(t, 1);
    shot('tour_menu');
    await t.tap(find.textContaining('Plus tard').last);
    await wait(t, 3);
    shot('tour_later');
    final lastTitles = t
        .widgetList<Text>(find.descendant(of: list, matching: find.byType(Text)))
        .map((w) => w.data)
        .toList();
    expect(lastTitles.contains(firstTitle), isTrue);
    expect(lastTitles[1] == firstTitle, isFalse, reason: 'la première étape a été repoussée');
  });
}
