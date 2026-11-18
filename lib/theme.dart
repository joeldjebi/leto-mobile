import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

// ============================================================================
// Identité LETO : violet (accent), noir (texte, éléments forts), gris (surfaces)
// ============================================================================

/// Violet LETO : boutons principaux, sélection, liens
const accent = Color(0xFF6D28D9);

/// Violet clair (dégradés, mode sombre)
const accentLight = Color(0xFF8B5CF6);

/// Violet profond (textes sur fond violet pâle)
const accentDeep = Color(0xFF4C1D95);

/// Noir LETO (titres, icônes fortes)
const ink = Color(0xFF121214);

/// Ancien nom conservé pour compatibilité
const letoOrange = accent;

const letoGradient = LinearGradient(
  colors: [accentLight, accent],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

/// Couleurs système (clair / sombre), accessibles via `Palette.of(context)`.
@immutable
class Palette extends ThemeExtension<Palette> {
  final Color background; // fond des écrans
  final Color card; // panneaux, cartes
  final Color elevated; // éléments posés sur une carte
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;
  final Color fill; // champs, pastilles, carte d'offre non sélectionnée
  final Color glass; // panneaux au-dessus de la carte
  final Color accentSoft; // fond violet pâle
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
    required this.accentSoft,
    required this.green,
    required this.red,
    required this.blue,
    required this.yellow,
  });

  static const light = Palette(
    background: Color(0xFFF3F3F6),
    card: Color(0xFFFFFFFF),
    elevated: Color(0xFFF3F3F6),
    label: ink,
    secondaryLabel: Color(0xFF6B6B76),
    tertiaryLabel: Color(0xFFA3A3AD),
    separator: Color(0xFFE6E6EB),
    fill: Color(0xFFF0F0F3),
    glass: Color(0xFAFFFFFF),
    accentSoft: Color(0xFFF1EBFE),
    green: Color(0xFF16A34A),
    red: Color(0xFFE11D48),
    blue: Color(0xFF2563EB),
    yellow: Color(0xFFD97706),
  );

  static const dark = Palette(
    background: Color(0xFF0B0B0D),
    card: Color(0xFF18181B),
    elevated: Color(0xFF232327),
    label: Color(0xFFF4F4F5),
    secondaryLabel: Color(0xFFA1A1AA),
    tertiaryLabel: Color(0xFF71717A),
    separator: Color(0xFF2A2A2F),
    fill: Color(0xFF232327),
    glass: Color(0xF518181B),
    accentSoft: Color(0xFF2A1D4A),
    green: Color(0xFF22C55E),
    red: Color(0xFFFB7185),
    blue: Color(0xFF60A5FA),
    yellow: Color(0xFFFBBF24),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>()!;

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 ? this : (other ?? this);
}

/// Typographie : Inter pour le texte, Barlow Condensed pour les grands titres
class TextStyles {
  static const _inter = 'Inter';
  static const _emoji = ['Apple Color Emoji', 'Noto Color Emoji'];

  /// Grand titre condensé, en capitales (« ENVOYER UN COLIS »)
  static const display = TextStyle(
    fontFamily: 'BarlowCondensed',
    fontSize: 34,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -0.2,
  );
  static const displaySmall = TextStyle(
    fontFamily: 'BarlowCondensed',
    fontSize: 25,
    fontWeight: FontWeight.w800,
    height: 1.05,
  );

  static const largeTitle = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 29,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
  );
  static const title1 = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 23,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
  );
  static const title2 = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );
  static const title3 = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 17.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
  );
  static const headline = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 15.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const body = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 15.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.2,
  );
  static const callout = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.15,
  );
  static const subheadline = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
  );
  static const footnote = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
  );
  static const caption = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
  );

  /// Prix (chiffres alignés)
  static const price = TextStyle(
    fontFamily: _inter,
    fontFamilyFallback: _emoji,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Durées et courbes des animations (légères et fluides)
class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 380);
  static const curve = Curves.easeOutCubic;
}

/// Transition de page : léger glissement + fondu (plus doux que le glissement iOS complet)
class LetoPageTransitionsBuilder extends PageTransitionsBuilder {
  const LetoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.curve,
      reverseCurve: Curves.easeInCubic,
    );
    final behind = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Motion.curve,
    );
    return SlideTransition(
      position: Tween(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(curved),
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: Offset.zero,
            end: const Offset(-0.03, 0),
          ).animate(behind),
          child: child,
        ),
      ),
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Inter',
    // Drapeaux et emojis : police couleur du système (sinon iOS dessine les lettres régionales en carrés)
    fontFamilyFallback: const ['Apple Color Emoji', 'Noto Color Emoji'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: accent,
      surface: p.card,
    ),
  );
  final pill = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(18),
  );
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    dividerColor: p.separator,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.fill,
    textTheme: base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: p.label,
      displayColor: p.label,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      primaryColor: accent,
      brightness: brightness,
      textTheme: CupertinoTextThemeData(
        primaryColor: accent,
        textStyle: TextStyles.body.copyWith(color: p.label),
        navLargeTitleTextStyle: TextStyles.largeTitle.copyWith(color: p.label),
        navTitleTextStyle: TextStyles.headline.copyWith(color: p.label),
        actionTextStyle: TextStyles.body.copyWith(color: accent),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: LetoPageTransitionsBuilder(),
        TargetPlatform.iOS:
            CupertinoPageTransitionsBuilder(), // garde le glisser-pour-revenir d'iOS
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
        backgroundColor: accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: accent.withValues(alpha: 0.35),
        disabledForegroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: pill,
        textStyle: TextStyles.headline.copyWith(fontSize: 16),
        animationDuration: Motion.fast,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        textStyle: TextStyles.body,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.fill,
      hintStyle: TextStyles.body.copyWith(color: p.tertiaryLabel),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark ? p.elevated : ink,
      contentTextStyle: TextStyles.subheadline.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.25),
    ),
  );
}
