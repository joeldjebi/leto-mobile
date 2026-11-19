import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leto/screens/searching_header.dart';
import 'package:leto/theme.dart';

Widget _app(Widget child, {double scale = 1, Brightness b = Brightness.light}) => MaterialApp(
  theme: buildTheme(b),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: child)),
    ),
  ),
);

void main() {
  testWidgets('Recherche : temps écoulé, livreurs, expiration, prix', (t) async {
    await t.pumpWidget(_app(SearchingHeader(
      createdAt: DateTime.now().subtract(const Duration(minutes: 2, seconds: 5)),
      nearby: 4, expiryMin: 30, price: '1 350 F', targeted: false,
    )));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Recherche d’un livreur'), findsOneWidget);
    expect(find.textContaining('Depuis 2 min'), findsOneWidget);
    expect(find.text('4 livreurs à proximité'), findsOneWidget);
    expect(find.text('Expire dans 28 min'), findsOneWidget);
    expect(find.text('1 350 F'), findsOneWidget);
  });

  testWidgets('Aucun livreur et expiration désactivée', (t) async {
    await t.pumpWidget(_app(SearchingHeader(createdAt: DateTime.now(), nearby: 0, expiryMin: 0, price: '900 F', targeted: false)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Aucun livreur autour'), findsOneWidget);
    expect(find.textContaining('Expire'), findsNothing);
    expect(find.textContaining('reste visible'), findsOneWidget);
  });

  testWidgets('Petit écran, grands caractères, sombre : pas de débordement', (t) async {
    t.view.physicalSize = const Size(320 * 3, 640 * 3);
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(_app(
      SearchingHeader(createdAt: DateTime.now(), nearby: 12, expiryMin: 120, price: '12 500 F', targeted: true),
      scale: 1.2,
      b: Brightness.dark,
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });
}
