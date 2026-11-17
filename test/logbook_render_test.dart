import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/theme.dart';
import 'package:leto/screens/logbook_screen.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MediaQuery(
      data: const MediaQueryData(size: Size(390, 844)),
      child: child,
    ),
  );

  testWidgets('Saisie : photo, adresse, destinataire, prix', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(const LogbookEntryScreen()));
    await t.pump();
    expect(find.text('Nouvelle livraison'), findsOneWidget);
    expect(find.text('Prendre le colis en photo'), findsOneWidget);
    expect(find.text('Enregistrer dans le carnet'), findsOneWidget);
    // Validation : sans photo → message, pas d'envoi
    await t.tap(find.text('Enregistrer dans le carnet'));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });

  testWidgets('Modification : formulaire prérempli', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(const LogbookEntryScreen(entry: {
      'id': 'x', 'address': 'Yopougon Maroc', 'recipientPhone': '0102030405',
      'recipientName': 'Awa', 'price': 1500, 'note': null, 'photoUrl': '/uploads/a.jpg',
    })));
    await t.pump();
    expect(find.text('Modifier la livraison'), findsOneWidget);
    expect(find.text('Yopougon Maroc'), findsOneWidget);
    expect(find.text('1500'), findsOneWidget);
  });

  testWidgets('Onglet carnet', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(const Scaffold(body: SingleChildScrollView(child: DriverLogbook()))));
    await t.pump();
    expect(find.text('Mon carnet'), findsOneWidget);
    expect(find.text('Nouvelle livraison'), findsOneWidget);
  });
}
