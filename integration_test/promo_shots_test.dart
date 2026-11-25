// Captures pour la landing et la vidéo de présentation (vraie app, vraie API locale, mise en scène par un script hôte).
// Client : flutter test integration_test/promo_shots_test.dart -d <simulateur> --dart-define=API_URL=local
//   --dart-define=DEV_PHONE=<cliente> --dart-define=DEV_PASSWORD=… --dart-define=DEV_LAT=5.3226 --dart-define=DEV_LNG=-4.0167
//   --dart-define=SCREENSHOTS=true --dart-define=THEME=light
// Livreur : mêmes options avec DEV_PHONE=<livreur> et --dart-define=DRIVER=true
// Le script hôte prend une capture du simulateur à chaque ligne « SHOT:nom ».
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> wait(WidgetTester t, double seconds) async {
  for (var i = 0; i < seconds * 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> shot(WidgetTester t, String name) async {
  // ignore: avoid_print
  print('SHOT:$name');
  await wait(t, 1.2); // le temps que l'hôte capture l'écran
}

Future<void> until(WidgetTester t, Finder f, {double seconds = 30}) async {
  for (var i = 0; i < seconds * 2 && f.evaluate().isEmpty; i++) {
    await wait(t, 0.5);
  }
}

Finder emptyField(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint && (w.controller?.text.isEmpty ?? false),
    );

Future<void> typeInto(WidgetTester t, Finder field, String text) async {
  final ctrl = (field.evaluate().first.widget as TextField).controller!;
  await t.tap(field.first);
  await wait(t, 0.3);
  ctrl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  await wait(t, 0.3);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('promo livreur', (t) async {
    app.main();
    await wait(t, 7);
    await shot(t, 'driver_home');
    final online = find.text('Passer en ligne');
    if (online.evaluate().isNotEmpty) {
      await t.tap(online);
      await wait(t, 2);
    }
    final card = find.textContaining('Riviera Golf');
    await until(t, card, seconds: 60);
    await wait(t, 3); // alerte plein écran
    await shot(t, 'driver_alert');
    // Ferme l'alerte sans accepter pour voir la liste
    final later = find.textContaining('Refuser');
    if (later.evaluate().isNotEmpty) {
      await t.tap(later.first);
      await wait(t, 2);
    }
    await shot(t, 'driver_list');
    if (card.evaluate().isNotEmpty) {
      await t.tap(card.first);
      await wait(t, 4);
      await shot(t, 'driver_sheet');
    }
  }, skip: !const bool.fromEnvironment('DRIVER'));

  testWidgets('promo client', (t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('leto_onboarding_seen', true);
    app.main();
    await wait(t, 9);
    await shot(t, 'home');

    await t.tap(find.text('Adresse de livraison').first);
    await wait(t, 1.2);
    await t.enterText(find.byType(CupertinoSearchTextField), 'Sococe');
    await until(t, find.text('SOCOCE'), seconds: 15);
    await wait(t, 1.5);
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 0.8);
    await shot(t, 'search');
    await t.tap(find.text('SOCOCE').first);
    await wait(t, 6);
    await shot(t, 'summary');

    await t.tap(find.textContaining('Continuer').first);
    await wait(t, 2.5);
    final name = emptyField('Nom du destinataire');
    if (name.evaluate().isNotEmpty) {
      await t.ensureVisible(name.first);
      await typeInto(t, name, 'Moussa Diabaté');
      final tel = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('07') && (w.controller?.text.isEmpty ?? false));
      if (tel.evaluate().isNotEmpty) {
        await t.ensureVisible(tel.first);
        await typeInto(t, tel, '0701020304');
      }
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 1.5);
    await t.scrollUntilVisible(find.text('Commander'), 200, scrollable: find.byType(Scrollable).first).catchError((_) {});
    await shot(t, 'order');
    await t.tap(find.text('Commander'));
    await wait(t, 3);
    await shot(t, 'share');
    await t.tap(find.text('Suivre la livraison'));
    await wait(t, 9); // le livreur accepte
    await shot(t, 'tracking_accepted');
    await wait(t, 20); // colis récupéré, en route
    await shot(t, 'tracking_live');
    await wait(t, 15);
    await shot(t, 'tracking_live2');
  }, skip: const bool.fromEnvironment('DRIVER'));
}
