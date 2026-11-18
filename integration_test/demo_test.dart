// Vidéo de démonstration : parcours client complet joué au rythme d'une présentation (vraie app, vraie API locale).
// flutter test integration_test/demo_test.dart -d <simulateur> --dart-define=API_URL=local --dart-define=DEMO_PHONE=07…
// Chaque ligne « MARK:nom:epochMs » repère le début d'une scène pour le montage.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

const phone = String.fromEnvironment('DEMO_PHONE');

Future<void> wait(WidgetTester t, double seconds) async {
  for (var i = 0; i < seconds * 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void mark(String name) {
  // ignore: avoid_print
  print('MARK:$name:${DateTime.now().millisecondsSinceEpoch}');
}

Finder emptyField(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint && (w.controller?.text.isEmpty ?? false),
    );

Future<Finder> scrollTo(WidgetTester t, Finder f, Finder list) async {
  for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
    await t.drag(list, const Offset(0, -300));
    await wait(t, 0.3);
  }
  await t.ensureVisible(f.first);
  await wait(t, 0.4);
  return f.first;
}

/// Saisie lettre par lettre (plus naturel à l'écran)
Future<void> type(WidgetTester t, Finder field, String text) async {
  for (var i = 1; i <= text.length; i++) {
    await t.enterText(field, text.substring(0, i));
    await wait(t, 0.07);
  }
}

/// Saisie dans un champ précis via son contrôleur (le champ reste ciblé même une fois rempli)
Future<void> typeInto(WidgetTester t, Finder field, String text) async {
  final ctrl = (field.evaluate().first.widget as TextField).controller!;
  await t.tap(field.first);
  await wait(t, 0.3);
  for (var i = 1; i <= text.length; i++) {
    ctrl.value = TextEditingValue(text: text.substring(0, i), selection: TextSelection.collapsed(offset: i));
    await wait(t, 0.07);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('démo livreur', (t) async {
    // Connexion automatique (DEV_PHONE) : on arrive directement sur l'accueil du livreur
    app.main();
    await wait(t, 6);
    mark('driver_home');
    await wait(t, 2.5);
    await t.tap(find.text('Passer en ligne'));
    await wait(t, 2);
    mark('online');
    // Une cliente commande près du livreur (script de mise en scène)
    final card = find.textContaining('Riviera Golf');
    for (var i = 0; i < 80 && card.evaluate().isEmpty; i++) {
      await wait(t, 0.5);
    }
    mark('new_order');
    await wait(t, 3);
    await t.tap(card.first);
    await wait(t, 3.5);
    mark('sheet');
    await wait(t, 2);
    await t.tap(find.textContaining('Accepter pour'));
    await wait(t, 3);
    mark('accepted');
    await wait(t, 9);
    mark('end');
  }, skip: !const bool.fromEnvironment('DRIVER'));

  testWidgets('démo client', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // premier lancement : présentation + connexion
    mark('start');
    app.main();
    await wait(t, 4);

    // Présentation en 3 écrans
    mark('onboarding');
    await wait(t, 2.6);
    for (var i = 0; i < 2; i++) {
      await t.timedDrag(find.byType(PageView), const Offset(-320, 0), const Duration(milliseconds: 420));
      await wait(t, 2.6);
    }
    await t.tap(find.text('Commencer'));
    await wait(t, 1.6);

    // Connexion
    mark('login');
    await type(t, find.byType(TextField).at(0), phone);
    await wait(t, 0.5);
    await type(t, find.byType(TextField).at(1), 'secret12');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 0.8);
    await t.tap(find.text('Continuer'));
    await wait(t, 5);

    // Accueil : carte et livreurs autour
    mark('home');
    await wait(t, 3.5);
    await t.tap(find.text('Adresse de livraison'));
    await wait(t, 1.2);
    mark('search');
    await type(t, find.byType(CupertinoSearchTextField), 'Sococe');
    await wait(t, 4);
    await t.tap(find.text('SOCOCE').first);
    await wait(t, 5);

    // Engins, délais et prix
    mark('summary');
    await wait(t, 3.5);
    await t.tap(find.textContaining('Continuer'));
    await wait(t, 2);

    // Destinataire
    mark('order');
    // ignore: avoid_print
    print('FIELDS:${find.byType(TextField).evaluate().map((e) => (e.widget as TextField).decoration?.hintText).toList()}');
    final name = emptyField('Nom du destinataire');
    if (name.evaluate().isEmpty) {
      final list = find.byType(Scrollable).first;
      await scrollTo(t, name, list);
    }
    await t.ensureVisible(name.first);
    await wait(t, 0.4);
    await typeInto(t, name, 'Moussa Diabaté');
    final tel = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('07') && (w.controller?.text.isEmpty ?? false));
    await t.ensureVisible(tel.first);
    await typeInto(t, tel, '0701020304');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 2);
    await t.tap(find.text('Commander'));
    await wait(t, 2);

    // Codes à partager, puis suivi en direct (un livreur accepte et arrive)
    mark('share');
    await wait(t, 3.5);
    await t.tap(find.text('Suivre la livraison'));
    await wait(t, 2);
    mark('tracking');
    await wait(t, 60);
    mark('end');
  }, skip: const bool.fromEnvironment('DRIVER'));
}
