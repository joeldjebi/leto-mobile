import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:leto/countries.dart';
import 'package:leto/screens/widgets.dart';
import 'package:leto/theme.dart';

const ci = Country.ci;
const gh = Country(
  iso: 'GH',
  name: 'Ghana',
  flag: '🇬🇭',
  dialCode: '233',
  phoneLength: 9,
  trunkPrefix: '0',
  phoneExample: '024 123 4567',
  currencyCode: 'GHS',
  currencySymbol: '₵',
  currencyDecimals: 2,
  sortOrder: 20,
);
const sn = Country(
  iso: 'SN',
  name: 'Sénégal',
  flag: '🇸🇳',
  dialCode: '221',
  phoneLength: 9,
  phoneExample: '77 123 45 67',
  currencyCode: 'XOF',
  currencySymbol: 'F',
  sortOrder: 10,
);
const fr = Country(
  iso: 'FR',
  name: 'France',
  flag: '🇫🇷',
  dialCode: '33',
  phoneLength: 9,
  trunkPrefix: '0',
  phoneExample: '06 12 34 56 78',
  currencyCode: 'EUR',
  currencySymbol: '€',
  currencyDecimals: 2,
  sortOrder: 30,
);

void main() {
  setUp(() => Countries.instance.setForTest([ci, sn, gh, fr], operating: 'CI'));
  tearDown(() => Countries.instance.setForTest([ci], operating: 'CI'));

  group('toE164 / validatePhone', () {
    test('Côte d’Ivoire : 10 chiffres, pas de préfixe national', () {
      expect(toE164(ci, '0701020304'), '+2250701020304');
      expect(toE164(ci, '07 01 02 03 04'), '+2250701020304');
      expect(toE164(ci, '070102030'), isNull);
      expect(toE164(ci, '07010203045'), isNull);
      expect(validatePhone(ci, '07 01 02 03 04'), isNull);
      expect(validatePhone(ci, ''), 'Indiquez le numéro de téléphone');
      expect(validatePhone(ci, '', required: false), isNull);
      expect(validatePhone(ci, '0701'), contains('10 chiffres'));
      expect(validatePhone(ci, '07ab'), contains('chiffres'));
    });

    test('Ghana : 9 chiffres, préfixe national « 0 » retiré', () {
      expect(toE164(gh, '241234567'), '+233241234567');
      expect(toE164(gh, '024 123 4567'), '+233241234567');
      expect(toE164(gh, '24123456'), isNull);
      // 10 chiffres sans le préfixe : invalide
      expect(toE164(gh, '1241234567'), isNull);
      expect(validatePhone(gh, '0241234567'), isNull);
      expect(validatePhone(gh, '2412'), contains('9 chiffres'));
    });
  });

  group('parseAnyPhone', () {
    test('formats du répertoire', () {
      expect(parseAnyPhone('+225 07 01 02 03 04'), '+2250701020304');
      expect(parseAnyPhone('00225 07-01-02-03-04'), '+2250701020304');
      expect(parseAnyPhone('2250701020304'), '+2250701020304');
      expect(parseAnyPhone('07 01 02 03 04'), '+2250701020304');
      expect(parseAnyPhone('(07) 01.02.03.04'), '+2250701020304');
      expect(parseAnyPhone('+233 024 123 4567'), '+233241234567');
      expect(parseAnyPhone('+233 24 123 4567'), '+233241234567');
      expect(parseAnyPhone('00233241234567'), '+233241234567');
      expect(parseAnyPhone('233241234567'), '+233241234567');
      expect(parseAnyPhone('+33 6 12 34 56 78'), '+33612345678');
    });

    test('invalides ou pays inconnus', () {
      expect(parseAnyPhone(''), isNull);
      expect(parseAnyPhone(null), isNull);
      expect(parseAnyPhone('12345'), isNull);
      expect(parseAnyPhone('+999 123 456 789'), isNull);
      expect(parseAnyPhone('+225 0701'), isNull);
    });

    test('numéro local : pays où LETO livre', () {
      Countries.instance.setForTest([ci, gh], operating: 'GH');
      expect(parseAnyPhone('024 123 4567'), '+233241234567');
      expect(parseAnyPhone('+2250701020304'), '+2250701020304');
    });

    test('samePhone compare les numéros normalisés', () {
      expect(samePhone('0701020304', '+2250701020304'), isTrue);
      expect(samePhone('+225 07 01 02 03 04', '+2250701020304'), isTrue);
      expect(samePhone('0701020305', '+2250701020304'), isFalse);
    });
  });

  group('formatPhone', () {
    test('drapeau, indicatif et groupement de l’exemple', () {
      expect(formatPhone('+2250701020304'), '+225 07 01 02 03 04');
      expect(formatPhone('+2250701020304', flag: false), '+225 07 01 02 03 04');
      // Exemple « 024 123 4567 » : le préfixe national est retiré du 1er groupe
      expect(formatPhone('+233241234567', flag: false), '+233 24 123 4567');
      expect(formatPhone('+33612345678', flag: false), '+33 6 12 34 56 78');
    });

    test('compact : pays où LETO livre au format local', () {
      expect(formatPhone('+2250701020304', compact: true), '07 01 02 03 04');
      expect(
        formatPhone('+233241234567', compact: true),
        '+233 24 123 4567',
      );
    });

    test('ancien format, valeurs inconnues', () {
      expect(formatPhone('0701020304'), '+225 07 01 02 03 04');
      expect(formatPhone('+999123456'), '+999123456');
      expect(formatPhone('abc'), 'abc');
      expect(formatPhone(null), '');
    });

    test('sans exemple : par paires', () {
      Countries.instance.setForTest([
        const Country(
          iso: 'XX',
          name: 'Test',
          dialCode: '999',
          phoneLength: 8,
          currencyCode: 'XXX',
          currencySymbol: 'X',
        ),
      ]);
      expect(formatPhone('+99912345678'), '+999 12 34 56 78');
    });
  });

  group('formatMoney', () {
    test('XOF : 0 décimale, comme avant (« 1 500 F »)', () {
      expect(formatMoney(1500), '1 500 F');
      expect(formatMoney(1500, 'XOF'), '1 500 F');
      expect(formatMoney(0), '0 F');
      expect(formatMoney(1234567), '1 234 567 F');
      expect(formatMoney(-500), '-500 F');
      expect(formatMoney(null), '0 F');
      // Devise inconnue : celle du pays où LETO livre
      expect(formatMoney(1500, 'ZZZ'), '1 500 F');
    });

    test('devise à 2 décimales', () {
      expect(formatMoney(1500, 'GHS'), '1 500 ₵');
      expect(formatMoney(12.5, 'GHS'), '12,50 ₵');
      expect(formatMoney(1234567.891, 'EUR'), '1 234 567,89 €');
    });

    test('devise du pays où LETO livre par défaut', () {
      Countries.instance.setForTest([ci, gh], operating: 'GH');
      expect(formatMoney(12.5), '12,50 ₵');
      expect(formatMoney(1500, 'XOF'), '1 500 F');
    });
  });

  group('PhoneController', () {
    test('initialisé depuis un E.164 : bon pays, chiffres nationaux', () {
      final c = PhoneController('+233241234567');
      expect(c.country, gh);
      expect(c.text, '241234567');
      expect(c.e164, '+233241234567');
      final d = PhoneController('0701020304');
      expect(d.country, ci);
      expect(d.e164, '+2250701020304');
      final e = PhoneController();
      expect(e.country, ci);
      expect(e.isBlank, isTrue);
      expect(e.e164, isNull);
    });
  });

  group('PhoneField', () {
    Widget app(Widget child, {double width = 390, double scale = 1}) =>
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 700),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: ListView(
                children: [
                  InsetGroup(header: 'Destinataire', children: [child]),
                ],
              ),
            ),
          ),
        );

    testWidgets('un seul pays : indicatif fixe, non cliquable', (t) async {
      Countries.instance.setForTest([ci]);
      final ctrl = PhoneController();
      await t.pumpWidget(app(PhoneField(controller: ctrl)));
      expect(find.text('+225'), findsOneWidget);
      expect(find.text('07 01 02 03 04'), findsOneWidget); // exemple
      expect(find.byIcon(PhosphorIconsBold.caretDown), findsNothing);
      await t.tap(find.byKey(const ValueKey('phone-country')));
      await t.pumpAndSettle();
      expect(find.text('Indicatif du pays'), findsNothing);
      await t.enterText(find.byType(TextFormField), '07 01 02 03 04');
      expect(ctrl.e164, '+2250701020304');
    });

    testWidgets('plusieurs pays : feuille, choix, E.164 émis', (t) async {
      final ctrl = PhoneController();
      final emitted = <String?>[];
      await t.pumpWidget(
        app(PhoneField(controller: ctrl, onChanged: emitted.add)),
      );
      expect(find.byIcon(PhosphorIconsBold.caretDown), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('phone-country')));
      await t.pumpAndSettle();
      expect(find.text('Indicatif du pays'), findsOneWidget);
      expect(find.text('Ghana'), findsOneWidget);
      expect(find.text('+233'), findsOneWidget);
      // 4 pays : pas de recherche
      expect(find.byType(CupertinoSearchTextField), findsNothing);
      await t.tap(find.text('Ghana'));
      await t.pumpAndSettle();
      expect(find.text('Indicatif du pays'), findsNothing);
      expect(find.text('+233'), findsOneWidget);
      expect(find.text('024 123 4567'), findsOneWidget); // exemple du Ghana
      await t.enterText(find.byType(TextFormField), '024 123 4567');
      expect(emitted.last, '+233241234567');
      expect(ctrl.e164, '+233241234567');
    });

    testWidgets('numéro international collé : pays reconnu', (t) async {
      final ctrl = PhoneController();
      await t.pumpWidget(app(PhoneField(controller: ctrl)));
      await t.enterText(find.byType(TextFormField), '+33 6 12 34 56 78');
      await t.pump();
      expect(ctrl.country, fr);
      expect(ctrl.text, '612345678');
      expect(ctrl.e164, '+33612345678');
    });

    testWidgets('plus de 6 pays : recherche', (t) async {
      Countries.instance.setForTest([
        ci,
        sn,
        gh,
        fr,
        for (final (iso, name, dial) in [
          ('ML', 'Mali', '223'),
          ('BF', 'Burkina Faso', '226'),
          ('TG', 'Togo', '228'),
        ])
          Country(
            iso: iso,
            name: name,
            dialCode: dial,
            phoneLength: 8,
            currencyCode: 'XOF',
            currencySymbol: 'F',
            sortOrder: 10,
          ),
      ], operating: 'CI');
      final ctrl = PhoneController();
      await t.pumpWidget(app(PhoneField(controller: ctrl)));
      await t.tap(find.byKey(const ValueKey('phone-country')));
      await t.pumpAndSettle();
      expect(find.byType(CupertinoSearchTextField), findsOneWidget);
      await t.enterText(find.byType(CupertinoSearchTextField), 'sene');
      await t.pump();
      expect(find.text('Sénégal'), findsOneWidget);
      expect(find.text('Togo'), findsNothing);
      await t.tap(find.text('Sénégal'));
      await t.pumpAndSettle();
      expect(ctrl.country, sn);
    });

    testWidgets('validation dans un formulaire', (t) async {
      final form = GlobalKey<FormState>();
      final ctrl = PhoneController();
      await t.pumpWidget(
        app(
          Form(
            key: form,
            child: PhoneField(controller: ctrl, validate: true),
          ),
        ),
      );
      expect(form.currentState!.validate(), isFalse);
      await t.pump();
      expect(find.text('Indiquez le numéro de téléphone'), findsOneWidget);
      await t.enterText(find.byType(TextFormField), '0701020304');
      expect(form.currentState!.validate(), isTrue);
    });

    testWidgets('320 px, texte à 120 % : pas de débordement', (t) async {
      t.view.physicalSize = const Size(320 * 3, 700 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final ctrl = PhoneController('+2250701020304');
      await t.pumpWidget(
        app(
          PhoneField(
            controller: ctrl,
            validate: true,
            trailing: ContactButton(onPressed: () {}),
          ),
          width: 320,
          scale: 1.2,
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('phone-country')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Indicatif du pays'), findsOneWidget);
    });
  });
}
