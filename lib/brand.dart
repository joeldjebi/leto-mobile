import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Symbole VITE : le soleil (8 rayons aux couleurs de la charte, 8 rayons fins, disque jaune, colis).
/// Dessiné en vectoriel, même géométrie que brand/sun.svg (repère de 800 unités centré).
class LetoMark extends StatelessWidget {
  final double size;

  /// Couleur des rayons fins : noir sur fond clair, blanc sur fond sombre
  final Color ink;
  const LetoMark({
    super.key,
    this.size = 48,
    this.ink = const Color(0xFF1A1A1A),
  });

  /// Version pour fond sombre (rayons fins blancs)
  const LetoMark.onAccent({super.key, this.size = 48}) : ink = Colors.white;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'VITE',
    child: CustomPaint(size: Size.square(size), painter: _SunPainter(ink)),
  );
}

class _SunPainter extends CustomPainter {
  final Color ink;
  _SunPainter(this.ink);

  static const _rays = [
    Color(0xFFFBC02D),
    Color(0xFFF9A825),
    Color(0xFFF28C1A),
    Color(0xFFE86A17),
    Color(0xFFE86A17),
    Color(0xFFF28C1A),
    Color(0xFFF9A825),
    Color(0xFFFBC02D),
  ];

  @override
  void paint(Canvas canvas, Size s) {
    final k = s.width / 800;
    canvas.translate(s.width / 2, s.height / 2);
    canvas.scale(k);
    // Rayons colorés (effilés vers le centre, bout arrondi)
    final ray = Path()
      ..moveTo(-24, -192)
      ..quadraticBezierTo(0, -186, 24, -192)
      ..lineTo(35, -311)
      ..arcToPoint(
        const Offset(-35, -311),
        radius: const Radius.circular(35),
        clockwise: false,
      )
      ..close();
    for (var i = 0; i < 8; i++) {
      canvas.save();
      canvas.rotate(i * math.pi / 4);
      canvas.drawPath(ray, Paint()..color = _rays[i]);
      canvas.restore();
    }
    // Rayons fins, alternativement longs et courts
    final thin = Paint()..color = ink;
    for (var i = 0; i < 8; i++) {
      final r2 = i.isEven ? 384.0 : 344.0;
      canvas.save();
      canvas.rotate(math.pi / 8 + i * math.pi / 4);
      canvas.drawRRect(
        RRect.fromLTRBR(-11, -r2, 11, -202, const Radius.circular(11)),
        thin,
      );
      canvas.restore();
    }
    canvas.drawCircle(
      Offset.zero,
      155,
      Paint()..color = const Color(0xFFFBC02D),
    );
    // Colis isométrique
    final k1 = Paint()..color = const Color(0xFF1A1A1A);
    final yellow = Paint()..color = const Color(0xFFFBC02D);
    canvas.drawPath(
      Path()
        ..moveTo(0, -89)
        ..lineTo(80, -43)
        ..lineTo(80, 47)
        ..lineTo(0, 93)
        ..lineTo(-80, 47)
        ..lineTo(-80, -43)
        ..close(),
      k1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(4, 3)
        ..lineTo(72, -36)
        ..lineTo(72, 43)
        ..lineTo(4, 82)
        ..close(),
      Paint()..color = const Color(0xFFF28C1A),
    );
    canvas.drawPath(
      Path()
        ..moveTo(-72, -40)
        ..lineTo(-68, -42)
        ..lineTo(2, -2)
        ..lineTo(2, 82)
        ..lineTo(-2, 82)
        ..lineTo(-2, 2)
        ..close(),
      yellow,
    );
    canvas.drawPath(
      Path()
        ..moveTo(2, -2)
        ..lineTo(70, -41)
        ..lineTo(72, -37)
        ..lineTo(4, 2)
        ..close(),
      yellow,
    );
    canvas.drawPath(
      Path()
        ..moveTo(-44, -60)
        ..lineTo(26, -20)
        ..lineTo(46, -32)
        ..lineTo(-24, -72)
        ..close(),
      yellow,
    );
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.ink != ink;
}
