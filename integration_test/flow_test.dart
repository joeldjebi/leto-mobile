// Parcours réels joués sur simulateur (vrais taps, vraie API).
// Lancer avec : flutter test integration_test/flow_test.dart -d <simulateur>
//   --dart-define=DEV_PHONE=... --dart-define=DEV_PASSWORD=... --dart-define=FLOW=client|driver
// Chaque ligne « SHOT:nom » marque un écran à capturer.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;

const flow = String.fromEnvironment('FLOW', defaultValue: 'client');

Future<void> wait(WidgetTester t, double seconds) async {
  for (var i = 0; i < seconds * 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> shot(WidgetTester t, String name) async {
  // ignore: avoid_print
  print('SHOT:$name');
  await wait(t, 3);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('parcours $flow', (t) async {
    app.main();
    await wait(t, 8);

    if (flow == 'client') {
      await shot(t, 'client_home');

      await t.tap(find.text('Adresse de livraison'));
      await wait(t, 1.5);
      await t.enterText(find.byType(TextField).first, 'Sococe');
      await wait(t, 5);
      await shot(t, 'client_search');

      await t.tap(find.byType(ListTile).at(1)); // 1er résultat (0 = « Choisir sur la carte »)
      await wait(t, 7);
      await shot(t, 'client_summary');

      await t.tap(find.textContaining('Continuer'));
      await wait(t, 2);
      await shot(t, 'client_order_top');

      await t.tap(find.byType(Switch)); // paiement à la livraison
      await wait(t, 0.5);
      await t.enterText(find.widgetWithText(TextFormField, 'Montant à encaisser (FCFA)'), '15000');
      await t.enterText(find.widgetWithText(TextFormField, 'Repère, étage, portail…').first, 'Boutique bleue à côté de la pharmacie');
      final recipient = find.widgetWithText(TextFormField, 'Nom du destinataire');
      await t.scrollUntilVisible(recipient, 200, scrollable: find.byType(Scrollable).first);
      await t.enterText(recipient, 'Mariam');
      await t.enterText(find.widgetWithText(TextFormField, 'Téléphone du destinataire'), '0166666666');
      final comment = find.widgetWithText(TextFormField, 'Commentaire pour le coursier (facultatif)');
      await t.scrollUntilVisible(comment, 200, scrollable: find.byType(Scrollable).first);
      await t.enterText(comment, 'Appelez en arrivant svp');
      FocusManager.instance.primaryFocus?.unfocus();
      await wait(t, 1);
      await shot(t, 'client_order_bottom');

      await t.tap(find.text('Commander'));
      await wait(t, 4);
      await shot(t, 'client_tracking');

      // Un livreur (script auto_offer.js) propose son prix → la proposition s'affiche
      await wait(t, 6);
      await shot(t, 'client_offers');
      await t.tap(find.text('Accepter'));
      await wait(t, 5);
      await shot(t, 'client_accepted');
    } else {
      await shot(t, 'driver_offline');
      await t.tap(find.text('Passer en ligne'));
      await wait(t, 6);
      await shot(t, 'driver_list');

      final course = find.textContaining('Riviera Golf').first;
      await t.ensureVisible(course);
      await wait(t, 1);
      await t.tap(course);
      await wait(t, 7);
      await shot(t, 'driver_sheet');

      // Proposez votre prix : +10 %
      final chip = find.byKey(const ValueKey('propose-1.1'));
      await t.ensureVisible(chip);
      await wait(t, 1);
      await t.tap(chip);
      await wait(t, 3);
      await shot(t, 'driver_offered');

      // Le client (script auto_accept.js) accepte → onglet « En cours »
      await wait(t, 8);
      await shot(t, 'driver_active');

      await t.tap(find.text('Gains'));
      await wait(t, 2);
      await shot(t, 'driver_gains');
    }
  });
}
