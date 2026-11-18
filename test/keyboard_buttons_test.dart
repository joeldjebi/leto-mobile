import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/independent_screens.dart';
import 'package:leto/screens/login_screen.dart';
import 'package:leto/theme.dart';

/// Écran de 390 × 844 avec un clavier ouvert de 320 px
Widget withKeyboard(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(viewInsets: const EdgeInsets.only(bottom: 320)),
      child: child,
    ),
  ),
);

void expectAboveKeyboard(WidgetTester t, String label) {
  final f = find.widgetWithText(FilledButton, label);
  expect(f, findsOneWidget);
  final r = t.getRect(f);
  expect(r.bottom <= 844 - 320, isTrue, reason: '« $label » est caché par le clavier (bas à ${r.bottom})');
  expect(r.top >= 0, isTrue);
}

void main() {
  setUp(() {});
  testWidgets('Connexion : « Continuer » au-dessus du clavier', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(withKeyboard(const LoginScreen()));
    await t.pump();
    expectAboveKeyboard(t, 'Continuer');
    // Inscription
    await t.scrollUntilVisible(find.text('Nouveau ? Créer un compte'), 120, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Nouveau ? Créer un compte'));
    await t.pumpAndSettle();
    expectAboveKeyboard(t, 'Créer mon compte');
  });

  testWidgets('Inscription livreur indépendant : bouton au-dessus du clavier', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(withKeyboard(const IndependentSignupScreen()));
    await t.pump();
    expectAboveKeyboard(t, 'Créer mon compte');
  });
}
