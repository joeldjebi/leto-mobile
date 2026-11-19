import 'package:flutter/material.dart';

/// Symbole LETO « Le code » : quatre points en L, le dernier validé (code de livraison).
/// Dessiné en vectoriel (même géométrie que brand/leto-mark.svg), centré dans [size].
class LetoMark extends StatelessWidget {
  final double size;
  final Color dots;
  final Color accent;
  const LetoMark({
    super.key,
    this.size = 48,
    this.dots = const Color(0xFF6D28D9),
    this.accent = const Color(0xFF22C55E),
  });

  /// Version blanche (sur fond violet)
  const LetoMark.onAccent({super.key, this.size = 48})
    : dots = Colors.white,
      accent = const Color(0xFF4ADE80);

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'LETO',
    child: CustomPaint(
      size: Size.square(size),
      painter: _MarkPainter(dots, accent),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  final Color dots, accent;
  _MarkPainter(this.dots, this.accent);

  @override
  void paint(Canvas canvas, Size s) {
    // Contenu du dessin : x 19 → 95.5, y 11 → 89 (repère 100) ; centré dans la zone
    final k = s.width / 80;
    canvas.translate(s.width / 2 - 57.25 * k, s.height / 2 - 50 * k);
    canvas.scale(k);
    final d = Paint()..color = dots;
    final a = Paint()..color = accent;
    canvas.drawCircle(const Offset(30, 22), 11, d);
    canvas.drawCircle(const Offset(30, 50), 11, d);
    canvas.drawCircle(const Offset(30, 78), 11, d);
    canvas.drawCircle(const Offset(60, 78), 11, a);
    final check = Path()
      ..moveTo(74, 46)
      ..lineTo(80, 52)
      ..lineTo(92, 38);
    canvas.drawPath(
      check,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.dots != dots || old.accent != accent;
}
