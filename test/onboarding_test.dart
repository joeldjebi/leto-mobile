import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/login_screen.dart';
import 'package:leto/screens/onboarding.dart';
import 'package:leto/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget app(Widget home, {Brightness b = Brightness.light, double scale = 1}) =>
    MaterialApp(
      theme: buildTheme(b),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: home,
        ),
      ),
    );

/// L'animation des illustrations tourne en boucle : avancer le temps par étapes
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'Splash puis 3 écrans de présentation, puis connexion ; vue une seule fois',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = const Size(390 * 3, 844 * 3);
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(app(const SplashScreen()));
      expect(find.text('LETO'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1600));
      await settle(t);
      expect(find.text('Commandez en 30 secondes'), findsOneWidget);
      expect(find.text('Passer'), findsOneWidget);
      await t.tap(find.text('Suivant'));
      await settle(t);
      expect(find.text('Suivez votre colis en direct'), findsOneWidget);
      await t.tap(find.text('Suivant'));
      await settle(t);
      expect(find.text('Livré à la bonne personne'), findsOneWidget);
      expect(find.text('Commencer'), findsOneWidget);
      await t.tap(find.text('Commencer'));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(LoginScreen), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('leto_onboarding_seen'), isTrue);
      // Relance : directement la connexion
      await t.pumpWidget(app(const SplashScreen(key: ValueKey(2))));
      await t.pump(const Duration(milliseconds: 1600));
      await settle(t);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

  for (final (name, size, scale, b) in [
    (
      'petit écran + grands caractères',
      const Size(320, 568),
      1.2,
      Brightness.light,
    ),
    ('sombre', const Size(390, 844), 1.0, Brightness.dark),
  ]) {
    testWidgets('Présentation sans débordement : $name', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = size * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(app(const OnboardingScreen(), b: b, scale: scale));
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        if (i < 2) await t.tap(find.text('Suivant'));
        await settle(t);
      }
    });
  }
}
