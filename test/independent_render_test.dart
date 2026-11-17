import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/independent_screens.dart';
import 'package:leto/screens/widgets.dart';
import 'package:leto/theme.dart';

Map<String, dynamic> dossier(String status, {String? note}) => {
  'status': status,
  'reviewNote': note,
  'commune': 'Yopougon',
  'birthDate': '1995-04-12',
  'idType': 'CNI',
  'vehicleType': 'MOTO',
  'links': {'selfieUrl': null},
  'required': [
    {'key': 'selfieUrl', 'label': 'selfie', 'ok': false},
    {'key': 'commune', 'label': 'commune', 'ok': true},
  ],
};

void main() {
  Widget app(Widget child, {double scale = 1, Brightness b = Brightness.light}) => MaterialApp(
    theme: buildTheme(b),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(scale).clamp(minScaleFactor: 0.9, maxScaleFactor: 1.2),
      ),
      child: child,
    ),
  );

  setUp(() {});

  testWidgets('Inscription : ce qu’il faut et le formulaire', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(const IndependentSignupScreen()));
    await t.pump();
    expect(find.text('Livreur indépendant'), findsWidgets);
    expect(find.text('Créer mon compte'), findsOneWidget);
    await t.tap(find.text('Créer mon compte'));
    await t.pump();
    expect(find.text('Nom complet obligatoire'), findsOneWidget);
  });

  testWidgets('Dossier brouillon : photos, identité, engin, accord', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1800 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(DossierScreen(initial: dossier('DRAFT'))));
    await t.pump();
    expect(find.text('Complétez votre dossier'), findsOneWidget);
    expect(find.text('Selfie'), findsOneWidget);
    expect(find.text('Carte grise'), findsOneWidget);
    expect(find.text('Envoyer le dossier'), findsOneWidget);
    expect(find.text('Yopougon'), findsOneWidget);
    expect(find.text('12/04/1995'), findsOneWidget);
  });

  testWidgets('Dossier refusé : motif et renvoi', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(DossierScreen(initial: dossier('REJECTED', note: 'CNI floue'))));
    await t.pump();
    expect(find.text('Dossier à corriger'), findsOneWidget);
    expect(find.text('CNI floue'), findsOneWidget);
    expect(find.text('Renvoyer le dossier'), findsOneWidget);
  });

  testWidgets('Dossier en attente : lecture seule', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(DossierScreen(initial: dossier('PENDING'))));
    await t.pump();
    expect(find.text('Dossier en cours de vérification'), findsOneWidget);
    expect(find.text('Envoyer le dossier'), findsNothing);
  });

  testWidgets('Badge et avertissement « livreur indépendant »', (t) async {
    await t.pumpWidget(app(const Scaffold(body: Column(children: [IndependentBadge(), IndependentNotice()]))));
    expect(find.text('LIVREUR INDÉPENDANT'), findsNWidgets(2));
    expect(find.textContaining('aucune entreprise partenaire'), findsOneWidget);
  });

  testWidgets('Grands caractères : pas de débordement', (t) async {
    t.view.physicalSize = const Size(360 * 3, 740 * 3);
    t.view.devicePixelRatio = 3;
    for (final w in [
      DossierScreen(initial: dossier('DRAFT')),
      const IndependentSignupScreen(),
      const Scaffold(body: IndependentNotice()),
    ]) {
      await t.pumpWidget(app(w, scale: 2));
      await t.pump();
      expect(t.takeException(), isNull);
    }
  });
}
