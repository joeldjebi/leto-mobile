import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/documents_screen.dart';
import 'package:leto/theme.dart';

String day(int n) => DateTime.now().add(Duration(days: n)).toIso8601String().substring(0, 10);

Map<String, dynamic> dossier({String insurance = 'SOON', String? licenseDate}) => {
  'status': 'APPROVED',
  'links': {'licenseUrl': null, 'insuranceUrl': null},
  'docs': {
    'license': {'expiresOn': licenseDate, 'state': licenseDate == null ? 'UNKNOWN' : 'OK'},
    'insurance': {'expiresOn': day(insurance == 'EXPIRED' ? -2 : 12), 'state': insurance},
  },
  'renewals': [
    {'id': 'r1', 'field': 'insuranceUrl', 'label': 'assurance', 'expiresOn': day(377), 'at': DateTime.now().toIso8601String()},
  ],
  'updateRequests': [
    {'id': 'u1', 'field': 'registrationUrl', 'label': 'carte grise', 'note': 'Photo floue', 'companyId': 'c', 'by': 'Awa', 'at': DateTime.now().toIso8601String()},
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

  testWidgets('Mes documents : validité, demande de l’entreprise, renouvellement', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1600 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(DocumentsScreen(initial: dossier(licenseDate: day(700)))));
    await t.pump();
    expect(find.text('Document bientôt expiré'), findsOneWidget);
    expect(find.text('Demandé par votre entreprise'.toUpperCase()), findsOneWidget);
    expect(find.textContaining('Photo floue'), findsOneWidget);
    expect(find.text('Expire bientôt'), findsOneWidget);
    expect(find.text('Valide'), findsOneWidget);
    expect(find.textContaining('en vérification'), findsWidgets);
    expect(find.text('Carte grise'), findsNWidgets(2)); // demande + liste
  });

  testWidgets('Mes documents : assurance expirée, date du permis à indiquer, sombre et grands caractères', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1800 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(DocumentsScreen(initial: dossier(insurance: 'EXPIRED')), scale: 2, b: Brightness.dark));
    await t.pump();
    expect(find.text('Document expiré'), findsOneWidget);
    expect(find.text('Expiré'), findsOneWidget);
    expect(find.text('Date à indiquer'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
