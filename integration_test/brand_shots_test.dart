// Captures de l'identité visuelle : démarrage, présentation, connexion (déconnecté).
// flutter test integration_test/brand_shots_test.dart -d <simulateur> --dart-define=API_URL=local --dart-define=SCREENSHOTS=true
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('identité : démarrage, présentation, connexion', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('leto_onboarding_seen');
    app.main();
    await wait(t, 0.8);
    shot('brand_splash');
    await wait(t, 4);
    shot('brand_onboarding');
    // Passe la présentation
    for (var i = 0; i < 4; i++) {
      final skip = find.textContaining('Passer');
      final next = find.textContaining('Suivant');
      final start = find.textContaining('Commencer');
      if (skip.evaluate().isNotEmpty) {
        await t.tap(skip.first);
        break;
      } else if (start.evaluate().isNotEmpty) {
        await t.tap(start.first);
        break;
      } else if (next.evaluate().isNotEmpty) {
        await t.tap(next.first);
      }
      await wait(t, 1);
    }
    await wait(t, 3);
    shot('brand_login');
    await wait(t, 1.5);
  });
}
