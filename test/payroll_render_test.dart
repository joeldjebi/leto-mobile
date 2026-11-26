import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/payroll_screen.dart';
import 'package:leto/theme.dart';

final data = <String, dynamic>{
  'enabled': true,
  'companyName': 'Express Cocody',
  'current': {
    'label': 'Semaine du 23 au 29 novembre 2026',
    'deliveries': 12,
    'stops': 31,
    'gross': 24650,
    'lines': [
      {'id': '1', 'kind': 'FIXED', 'label': 'Fixe de la période', 'amount': 10000},
      {'id': '2', 'kind': 'STOPS', 'label': '31 colis livré(s) × 300 F', 'amount': 9300},
      {'id': '3', 'kind': 'ADVANCE', 'label': 'Avance du 25/11/2026', 'amount': -3000},
    ],
  },
  'payslips': [
    {'id': 'p1', 'label': 'Semaine du 16 au 22 novembre 2026', 'status': 'PAID', 'net': 18400, 'deliveries': 10, 'stops': 25, 'lines': [], 'method': 'MOBILE_MONEY'},
    {'id': 'p2', 'label': 'Semaine du 9 au 15 novembre 2026', 'status': 'CONFIRMED', 'net': 21000, 'lines': []},
  ],
  'advances': [
    {'id': 'a1', 'amount': 3000, 'status': 'GIVEN'},
  ],
};

void main() {
  Widget app(Widget child, {double scale = 1, Brightness b = Brightness.light}) => MaterialApp(
    theme: buildTheme(b),
    home: MediaQuery(
      data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(scale).clamp(minScaleFactor: 0.9, maxScaleFactor: 1.2)),
      child: child,
    ),
  );

  testWidgets('Ma paye : estimation, fiches, avances', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1800 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(PayrollScreen(initial: data)));
    await t.pump();
    expect(find.textContaining('SEMAINE DU 23 AU 29 NOVEMBRE 2026'), findsOneWidget);
    expect(find.text('Estimation'), findsOneWidget);
    expect(find.text('Demander une avance'), findsOneWidget);
    expect(find.text('À confirmer'), findsOneWidget);
    expect(find.text('Reçue'), findsOneWidget);
    expect(find.textContaining('retenue sur la prochaine paie'), findsOneWidget);
  });

  testWidgets('Ma paye : non activée, sombre, grands caractères', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1200 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(app(const PayrollScreen(initial: {'enabled': false}), scale: 2, b: Brightness.dark));
    await t.pump();
    expect(find.text('Paye non activée'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
