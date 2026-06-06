import 'dart:math';
import 'package:flutter/material.dart';

class Starfield extends StatefulWidget {
  const Starfield({super.key});

  @override
  State<Starfield> createState() => _StarfieldState();
}

class _StarfieldState extends State<Starfield> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<_Star> _stars = [];
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat(reverse: true);
    for (int i = 0; i < 80; i++) {
      _stars.add(_Star(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        size: _rng.nextDouble() * 2 + 0.5,
        opacity: _rng.nextDouble() * 0.6 + 0.2,
        phase: _rng.nextDouble(),
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => CustomPaint(
        painter: _StarPainter(_stars, _controller.value),
        size: Size.infinite,
      ),
    );
  }
}

class _Star {
  final double x, y, size, opacity, phase;
  const _Star({required this.x, required this.y, required this.size, required this.opacity, required this.phase});
}

class _StarPainter extends CustomPainter {
  final List<_Star> stars;
  final double t;
  _StarPainter(this.stars, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in stars) {
      final twinkle = (sin((t + s.phase) * 2 * pi) + 1) / 2;
      final paint = Paint()..color = Colors.white.withOpacity(s.opacity * (0.4 + 0.6 * twinkle));
      canvas.drawCircle(Offset(s.x * size.width, s.y * size.height), s.size, paint);
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.t != t;
}
