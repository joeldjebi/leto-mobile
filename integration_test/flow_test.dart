// Parcours réels joués sur simulateur (vrais taps, vraie API).
// flutter test integration_test/flow_test.dart -d <simulateur> --dart-define=FLOW=client|driver|dispute|prodcheck
//   (parcours client/driver/dispute : ajouter --dart-define=API_URL=local pour l'API de votre Mac)
//   --dart-define=DEV_PHONE=... --dart-define=DEV_PASSWORD=... --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
// Chaque ligne « SHOT:nom » marque un écran à capturer.
import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leto/main.dart' as app;
import 'package:leto/screens/widgets.dart';

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

/// Fait défiler [list] jusqu'à ce que [f] existe, puis l'amène à l'écran
Future<Finder> scrollTo(WidgetTester t, Finder f, Finder list) async {
  for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
    await t.drag(list, const Offset(0, -380));
    await wait(t, 0.3);
  }
  await t.ensureVisible(f.first);
  await wait(t, 0.5);
  return f.first;
}

/// Champ de saisie vide ayant ce texte indicatif
Finder emptyField(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint && (w.controller?.text.isEmpty ?? false),
    );

/// Fait défiler le panneau (CustomScrollView) jusqu'à [f], puis appuie dessus
Future<void> tapVisible(WidgetTester t, Finder f) async {
  final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
  await t.tap(await scrollTo(t, f, list));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('parcours $flow', (t) async {
    app.main();
    await wait(t, 8);

    if (flow == 'tracking') {
      // Suivi de la livraison en cours (préparée par l'API)
      await t.tap(find.textContaining('Livraison en cours').first);
      await wait(t, 5);
      await shot(t, const String.fromEnvironment('SHOT', defaultValue: 'track'));
      final list = find.byType(Scrollable).last;
      await t.drag(list, const Offset(0, -400));
      await wait(t, 1.5);
      await shot(t, '${const String.fromEnvironment('SHOT', defaultValue: 'track')}_b');
    } else if (flow == 'driveractive') {
      await t.tap(find.textContaining('En cours').first);
      await wait(t, 4);
      await shot(t, 'driver_active_now');
    } else if (flow == 'register') {
      await t.tap(find.text('Nouveau ? Créer un compte'));
      await wait(t, 1);
      await shot(t, 'register_individual');
      await t.tap(find.text('Boutique'));
      await wait(t, 1);
      await shot(t, 'register_shop');
    } else if (flow == 'prodcheck') {
      // Vérifie que l'app joint l'API configurée : un mauvais mot de passe doit renvoyer l'erreur du serveur
      await t.enterText(find.byType(TextField).at(0), '0700000001');
      await t.enterText(find.byType(TextField).at(1), 'mauvais-mot-de-passe');
      await t.tap(find.text('Continuer'));
      final error = find.textContaining('mot de passe incorrect');
      for (var i = 0; i < 20 && error.evaluate().isEmpty; i++) {
        await wait(t, 0.5);
      }
      // ignore: avoid_print
      print('API_RESPONSE:${error.evaluate().isNotEmpty ? 'serveur joint (erreur attendue reçue)' : 'AUCUNE réponse du serveur'}');
      expect(error, findsOneWidget);
      // ignore: avoid_print
      print('SHOT:prodcheck');
      await wait(t, 1);
    } else if (flow == 'client') {
      await shot(t, 'client_home');
      if (const bool.fromEnvironment('UI_ONLY')) {
        await t.tap(find.byType(MapButton).first);
        await wait(t, 1);
        await t.tap(find.text('Mon profil'));
        await wait(t, 1.5);
        await shot(t, 'client_profile');
        await t.tap(find.byIcon(PhosphorIconsBold.caretLeft).first);
        await wait(t, 1.5);
      }

      // 1re adresse : recherche d'un lieu
      await t.tap(find.text('Adresse de livraison'));
      await wait(t, 1.5);
      await t.enterText(find.byType(CupertinoSearchTextField), 'Sococe');
      await wait(t, 5);
      await shot(t, 'client_search');
      await t.tap(find.text('SOCOCE').first);
      await wait(t, 6);

      // 2e et 3e adresses : depuis le carnet d'adresses
      for (final name in ['Aya', 'Koffi']) {
        await t.tap(find.textContaining('Arrêts'));
        await wait(t, 1.5);
        if (name == 'Koffi') await shot(t, 'client_stops');
        await t.tap(find.text('Ajouter un arrêt'));
        await wait(t, 3);
        await t.tap(find.text(name).first);
        await wait(t, 6);
      }
      await shot(t, 'client_summary');
      if (const bool.fromEnvironment('UI_ONLY')) {
        await t.tap(find.textContaining('Continuer'));
        await wait(t, 2);
        await shot(t, 'client_order_top');
        // Changer l'adresse de départ en la choisissant sur la carte
        await t.tap(find.text('Modifier l’adresse').first);
        await wait(t, 1.5);
        await t.tap(find.text('Choisir sur la carte'));
        await wait(t, 4);
        await shot(t, 'client_map_picker');
        await t.tap(find.text('Valider cette adresse'));
        await wait(t, 5);
        final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
        await t.drag(list, const Offset(0, -500));
        await wait(t, 1);
        await shot(t, 'client_order_mid');
        await t.drag(list, const Offset(0, -900));
        await wait(t, 1);
        await shot(t, 'client_order_bottom');
        return;
      }

      await t.tap(find.textContaining('Continuer'));
      await wait(t, 2);
      await shot(t, 'client_order_top');

      // Le destinataire saisi à la main (les autres viennent du carnet)
      final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
      final name = emptyField('Nom du destinataire');
      await t.enterText(await scrollTo(t, name, list), 'Mariam');
      final phone = emptyField('Téléphone');
      await t.enterText(await scrollTo(t, phone, list), '0166666666');
      // Paiement à la livraison : seulement si l'admin l'a activé
      final cod = find.byType(CupertinoSwitch);
      if (cod.evaluate().isNotEmpty) {
        await t.tap(await scrollTo(t, cod, list));
        await wait(t, 0.8);
        await t.enterText(await scrollTo(t, emptyField('Montant à encaisser'), list), '15000');
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await wait(t, 1);
      await shot(t, 'client_order_mid');

      await t.tap(find.text('Commander'));
      await wait(t, 1.2);
      // ignore: avoid_print
      print('SHOT:client_after_order');
      await wait(t, 5);
      await shot(t, 'client_share');
      if (const bool.fromEnvironment('ORDER_ONLY')) return;
      await t.tap(find.text('Suivre la livraison'));
      await wait(t, 4);
      await shot(t, 'client_tracking');

      // Un livreur (script auto_offer.js) propose son prix
      await wait(t, 6);
      await shot(t, 'client_offers');
      await t.tap(find.text('Accepter'));
      await wait(t, 5);
      await shot(t, 'client_accepted');
    } else if (flow == 'dispute') {
      // L'expéditeur voit l'échec (photo, GPS) et conteste
      await t.tap(find.byIcon(PhosphorIconsBold.userCircle));
      await wait(t, 1.5);
      await t.tap(find.text('Mes livraisons'));
      await wait(t, 3);
      await t.tap(find.text('Pharmacie Riviera Golf').first);
      await wait(t, 6);
      final list = find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)).first;
      await scrollTo(t, find.text('Contester'), list);
      await shot(t, 'dispute_failed');
      await t.tap(find.text('Contester'));
      await wait(t, 1.5);
      await t.enterText(find.byType(CupertinoTextField), 'Fatou était chez elle, elle n’a reçu aucun appel');
      await shot(t, 'dispute_prompt');
      await t.tap(find.text('Contester').last);
      await wait(t, 4);
      await shot(t, 'dispute_sent');
    } else {
      await shot(t, 'driver_offline');
      if (const bool.fromEnvironment('UI_ONLY')) return;
      await t.tap(find.text('Passer en ligne'));
      await wait(t, 6);
      await shot(t, 'driver_list');

      await tapVisible(t, find.textContaining('Riviera Golf').first);
      await wait(t, 7);
      await shot(t, 'driver_sheet');
      await t.tap(find.textContaining('Accepter pour'));
      await wait(t, 5);
      await shot(t, 'driver_pickup');

      await tapVisible(t, find.textContaining('J’ai récupéré'));
      // L'arrivée chez le 1er destinataire est détectée par le serveur au prochain envoi GPS (≤ 20 s)
      await wait(t, 24);
      await shot(t, 'driver_arrived');

      // Attente obligatoire (ABSENCE_WAIT_MIN=1 en développement), puis absence avec preuves
      await wait(t, 40);
      await shot(t, 'driver_before_problem');
      await tapVisible(t, find.text('Signaler un problème'));
      await wait(t, 1.5);
      await shot(t, 'driver_problem');
      await t.tap(find.text('Destinataire absent ou injoignable'));
      await wait(t, 1.5);
      await t.enterText(find.byType(CupertinoTextField), 'Portail fermé, 3 appels sans réponse');
      await t.tap(find.text('Envoyer'));
      await wait(t, 5);
      await shot(t, 'driver_next_stop');

      await t.tap(find.text('Gains'));
      await wait(t, 2);
      await shot(t, 'driver_gains');
    }
  });
}
