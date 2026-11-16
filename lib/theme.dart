import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Couleur d'accent LETO
const letoOrange = Color(0xFFF77F00);

/// Couleurs système façon iOS (clair / sombre), accessibles via `Palette.of(context)`.
@immutable
class Palette extends ThemeExtension<Palette> {
  final Color background; // fond des écrans « groupés » (Réglages)
  final Color card; // cellules / cartes
  final Color elevated; // éléments posés sur une carte
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;
  final Color fill; // champs, pastilles
  final Color glass; // panneaux translucides au-dessus de la carte
  final Color green;
  final Color red;
  final Color blue;
  final Color yellow;

  const Palette({
    required this.background,
    required this.card,
    required this.elevated,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.fill,
    required this.glass,
    required this.green,
    required this.red,
    required this.blue,
    required this.yellow,
  });

  static const light = Palette(
    background: Color(0xFFF2F2F7),
    card: Color(0xFFFFFFFF),
    elevated: Color(0xFFF2F2F7),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    separator: Color(0x4A3C3C43),
    fill: Color(0x1F787880),
    glass: Color(0xD9FFFFFF),
    green: Color(0xFF34C759),
    red: Color(0xFFFF3B30),
    blue: Color(0xFF007AFF),
    yellow: Color(0xFFFFCC00),
  );

  static const dark = Palette(
    background: Color(0xFF000000),
    card: Color(0xFF1C1C1E),
    elevated: Color(0xFF2C2C2E),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    separator: Color(0x99545458),
    fill: Color(0x3D787880),
    glass: Color(0xCC1C1C1E),
    green: Color(0xFF30D158),
    red: Color(0xFFFF453A),
    blue: Color(0xFF0A84FF),
    yellow: Color(0xFFFFD60A),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>()!;

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 ? this : (other ?? this);
}

/// Styles de texte de la charte Apple (Human Interface Guidelines)
class TextStyles {
  static const largeTitle = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.37,
  );
  static const title1 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.36,
  );
  static const title2 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.35,
  );
  static const title3 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.38,
  );
  static const headline = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
  );
  static const body = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.41,
  );
  static const callout = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
  );
  static const subheadline = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
  );
  static const footnote = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
  );
  static const caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w400);
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: letoOrange,
      brightness: brightness,
      primary: letoOrange,
      surface: p.card,
    ),
  );
  final shape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(14),
  );
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    dividerColor: p.separator,
    splashFactory: NoSplash
        .splashFactory, // pas d'ondulation Material : effet de pression iOS
    highlightColor: p.fill,
    cupertinoOverrideTheme: CupertinoThemeData(
      primaryColor: letoOrange,
      brightness: brightness,
    ),
    // Navigation iOS (glisser pour revenir) sur toutes les plateformes
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.label,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyles.headline.copyWith(color: p.label),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: letoOrange,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: shape,
        textStyle: TextStyles.headline,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: letoOrange,
        textStyle: TextStyles.body,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.fill,
      hintStyle: TextStyles.body.copyWith(color: p.tertiaryLabel),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark
          ? p.elevated
          : const Color(0xF21C1C1E),
      contentTextStyle: TextStyles.subheadline.copyWith(color: Colors.white),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
    ),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: letoOrange),
  );
}
