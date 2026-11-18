import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../brand.dart';
import '../labels.dart';
import '../main.dart';

const _seenKey = 'leto_onboarding_seen';

/// Écran de démarrage animé : prend le relais du splash natif (même fond violet,
/// même pictogramme), puis ouvre la présentation au premier lancement ou l'accueil.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final prefs = SharedPreferences.getInstance();
    await _c.forward();
    final seen = (await prefs).getBool(_seenKey) ?? false;
    if (!mounted) return;
    // Déjà connecté : pas de présentation (utilisateur existant)
    final next = seen || Api.instance.isLoggedIn
        ? homeFor()
        : const OnboardingScreen();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, _, _) => next,
        transitionsBuilder: (_, a, _, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    // Identique au splash natif : même violet uni, même symbole blanc à la même taille et à la
    // même place (aucune tuile, aucun texte). Seul un léger « battement » du symbole s'ajoute.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: accent,
        body: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final t = reduce ? 0.0 : _c.value;
              return Transform.scale(
                scale: 1 + 0.06 * math.sin(t * math.pi),
                child: child,
              );
            },
            child: const LetoMark.onAccent(size: splashMarkSize),
          ),
        ),
      ),
    );
  }
}

/// Taille du symbole du splash (dp) : celle du splash natif (assets/brand/splash_logo.png,
/// symbole de 440 px sur 1152 px affichés à 288 dp)
const splashMarkSize = 110.0;

class _Page {
  final String title;
  final String text;
  final Widget Function(Animation<double> float) art;
  const _Page(this.title, this.text, this.art);
}

/// Présentation en 3 écrans, affichée une seule fois
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final _pc = PageController();
  int _i = 0;
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  static final _pages = [
    _Page(
      'Commandez en 30 secondes',
      'Posez l’adresse, le prix s’affiche tout de suite. Jusqu’à 10 destinataires dans une même course.',
      (f) => _OrderArt(float: f),
    ),
    _Page(
      'Suivez votre colis en direct',
      'La position du livreur, l’heure d’arrivée et une notification à chaque étape.',
      (f) => _TrackArt(float: f),
    ),
    _Page(
      'Livré à la bonne personne',
      'Code du destinataire, photo et position GPS : chaque remise est prouvée.',
      (f) => _DeliveredArt(float: f),
    ),
  ];

  @override
  void dispose() {
    _pc.dispose();
    _float.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seenKey, true);
    if (mounted) goHome(context);
  }

  void _next() {
    if (_i == _pages.length - 1) {
      _finish();
    } else {
      _pc.nextPage(duration: Motion.slow, curve: Motion.curve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final last = _i == _pages.length - 1;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedOpacity(
                  opacity: last ? 0 : 1,
                  duration: Motion.fast,
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    onPressed: last ? null : _finish,
                    child: Text(
                      'Passer',
                      style: TextStyles.body.copyWith(
                        color: p.secondaryLabel,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pc,
                itemCount: _pages.length,
                onPageChanged: (i) {
                  HapticFeedback.selectionClick();
                  setState(() => _i = i);
                },
                itemBuilder: (context, i) {
                  final pg = _pages[i];
                  return LayoutBuilder(
                    builder: (context, c) => SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: c.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              height: math.min(340, c.maxHeight * 0.58),
                              child: pg.art(_float),
                            ),
                            const SizedBox(height: 32),
                            Text(
                              pg.title,
                              textAlign: TextAlign.center,
                              style: TextStyles.largeTitle.copyWith(
                                color: p.label,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              pg.text,
                              textAlign: TextAlign.center,
                              style: TextStyles.body.copyWith(
                                color: p.secondaryLabel,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                children: [
                  Semantics(
                    label: 'Écran ${_i + 1} sur ${_pages.length}',
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var k = 0; k < _pages.length; k++)
                          AnimatedContainer(
                            duration: Motion.medium,
                            curve: Motion.curve,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: k == _i ? 24 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: k == _i ? accent : p.separator,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(last ? 'Commencer' : 'Suivant'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Illustrations (dessinées en widgets, s'adaptent au thème) ----------

double _wave(Animation<double> a, [double phase = 0]) =>
    math.sin((a.value + phase) * 2 * math.pi);

/// Fond commun : grand disque violet pâle avec une grille de « rues »
class _Stage extends StatelessWidget {
  final List<Widget> children;
  const _Stage({required this.children});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final d = math.min(c.maxWidth, c.maxHeight);
        return Center(
          child: SizedBox(
            width: d,
            height: d,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.accentSoft,
                    ),
                    child: ClipOval(
                      child: CustomPaint(painter: _StreetsPainter(p.card)),
                    ),
                  ),
                ),
                ...children,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StreetsPainter extends CustomPainter {
  final Color color;
  _StreetsPainter(this.color);
  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = s.width * 0.035
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, s.height * 0.32),
      Offset(s.width, s.height * 0.22),
      paint,
    );
    canvas.drawLine(
      Offset(0, s.height * 0.74),
      Offset(s.width, s.height * 0.66),
      paint,
    );
    canvas.drawLine(
      Offset(s.width * 0.3, 0),
      Offset(s.width * 0.38, s.height),
      paint,
    );
    canvas.drawLine(
      Offset(s.width * 0.74, 0),
      Offset(s.width * 0.66, s.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_StreetsPainter old) => old.color != color;
}

/// Petite carte flottante (bulle d'information)
class _Bubble extends StatelessWidget {
  final Widget child;
  const _Bubble({required this.child});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  const _Badge(this.icon, {this.size = 64, this.color = accent});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.48),
    );
  }
}

/// 1. Adresse posée + prix immédiat
class _OrderArt extends StatelessWidget {
  final Animation<double> float;
  const _OrderArt({required this.float});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: float,
      builder: (context, _) => _Stage(
        children: [
          Align(
            alignment: const Alignment(-0.1, -0.05),
            child: Transform.translate(
              offset: Offset(0, -6 * _wave(float).abs()),
              child: const Icon(
                CupertinoIcons.location_solid,
                size: 88,
                color: accent,
              ),
            ),
          ),
          Align(
            alignment: Alignment(-0.95, -0.72 + 0.03 * _wave(float, 0.2)),
            child: _Bubble(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.cube_box_fill,
                    color: accent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Marcory, Zone 4',
                      style: TextStyles.subheadline.copyWith(
                        color: p.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment(0.95, 0.62 + 0.03 * _wave(float, 0.6)),
            child: _Bubble(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Prix fixé',
                    style: TextStyles.caption.copyWith(color: p.secondaryLabel),
                  ),
                  Text(
                    formatMoney(1500),
                    style: TextStyles.displaySmall.copyWith(color: p.label),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2. Moto sur l'itinéraire + heure d'arrivée
class _TrackArt extends StatelessWidget {
  final Animation<double> float;
  const _TrackArt({required this.float});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: float,
      builder: (context, _) {
        final t = (float.value * 1.0) % 1.0;
        return _Stage(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _RoutePainter(t, p.card)),
            ),
            Align(
              alignment: Alignment(-0.92, 0.82 + 0.03 * _wave(float, 0.4)),
              child: _Bubble(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: p.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Arrive dans 8 min',
                        style: TextStyles.subheadline.copyWith(
                          color: p.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Itinéraire courbe ; la moto avance le long du tracé
class _RoutePainter extends CustomPainter {
  final double t;
  final Color ring;
  _RoutePainter(this.t, this.ring);

  Path _path(Size s) => Path()
    ..moveTo(s.width * 0.18, s.height * 0.72)
    ..cubicTo(
      s.width * 0.3,
      s.height * 0.3,
      s.width * 0.62,
      s.height * 0.86,
      s.width * 0.8,
      s.height * 0.3,
    );

  @override
  void paint(Canvas canvas, Size s) {
    final path = _path(s);
    final metric = path.computeMetrics().first;
    final w = s.width * 0.03;
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round,
    );
    // Partie parcourue
    final pos = 0.08 + 0.84 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
    canvas.drawPath(
      metric.extractPath(0, metric.length * pos),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round,
    );
    // Départ et arrivée
    final start = metric.getTangentForOffset(0)!.position;
    final end = metric.getTangentForOffset(metric.length)!.position;
    canvas.drawCircle(start, w * 1.1, Paint()..color = ring);
    canvas.drawCircle(start, w * 0.7, Paint()..color = accent);
    canvas.drawCircle(end, w * 1.6, Paint()..color = ring);
    canvas.drawCircle(end, w * 1.1, Paint()..color = const Color(0xFF34C759));
    // Moto
    final m = metric.getTangentForOffset(metric.length * pos)!.position;
    final r = s.width * 0.085;
    canvas.drawCircle(
      m.translate(0, 3),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(m, r, Paint()..color = Colors.white);
    canvas.drawCircle(m, r - 3, Paint()..color = accent);
    final icon = Icons.two_wheeler;
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: r * 1.1,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, m - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.t != t || old.ring != ring;
}

/// 3. Code du destinataire + preuve
class _DeliveredArt extends StatelessWidget {
  final Animation<double> float;
  const _DeliveredArt({required this.float});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: float,
      builder: (context, _) => _Stage(
        children: [
          Align(
            alignment: const Alignment(0, -0.05),
            child: Transform.translate(
              offset: Offset(0, 4 * _wave(float)),
              child: _Bubble(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Code de livraison',
                        style: TextStyles.footnote.copyWith(
                          color: p.secondaryLabel,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final d in ['4', '8', '1', '7'])
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: 38,
                              height: 46,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: p.accentSoft,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                d,
                                style: TextStyles.title1.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment(0.62, -0.62 + 0.03 * _wave(float, 0.3)),
            child: _Badge(CupertinoIcons.checkmark_alt, color: p.green),
          ),
          Align(
            alignment: Alignment(-0.7, 0.66 + 0.03 * _wave(float, 0.7)),
            child: const _Badge(CupertinoIcons.camera_fill, size: 52),
          ),
          Align(
            alignment: Alignment(0.55, 0.78 + 0.03 * _wave(float, 0.5)),
            child: const _Badge(
              CupertinoIcons.location_fill,
              size: 46,
              color: accentDeep,
            ),
          ),
        ],
      ),
    );
  }
}
