import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Staggered entrance: silky smooth fade + subtle vertical slide.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration stagger;
  final double offsetY;
  final Duration duration;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.stagger = const Duration(milliseconds: 50),
    this.offsetY = 14,
    this.duration = const Duration(milliseconds: 360),
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    final delayMs = (widget.stagger.inMilliseconds * widget.index).clamp(0, 450);
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fadeCurve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    final slideCurve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: fadeCurve,
      child: AnimatedBuilder(
        animation: slideCurve,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, widget.offsetY * (1 - slideCurve.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Number that rolls to its new value with crisp monospace format.
class AnimatedCounter extends StatelessWidget {
  final num value;
  final TextStyle? style;
  final String suffix;
  final int decimals;

  const AnimatedCounter({
    super.key,
    required this.value,
    this.style,
    this.suffix = '',
    this.decimals = 0,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: AppDurations.slow,
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) => Text(
        '${animated.toStringAsFixed(decimals)}$suffix',
        style: style,
      ),
    );
  }
}

/// Snappy Neo-brutalist button click interaction (smooth scale + slight translation).
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const PressableScale({super.key, required this.child, this.onTap});

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_pressed ? 1.5 : 0.0, _pressed ? 1.5 : 0.0, 0.0),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Architectural Neo-Brutalist Technical Grid Backdrop.
/// Renders 1px hairline grid matrix and crosshair coordinate ticks.
class TechnicalGridBackdrop extends StatelessWidget {
  final Widget child;
  final Color gridColor;
  final double gridSize;

  const TechnicalGridBackdrop({
    super.key,
    required this.child,
    this.gridColor = const Color(0xFFE5E5DF),
    this.gridSize = 32.0,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _TechnicalGridPainter(gridColor: gridColor, gridSize: gridSize),
      child: child,
    );
  }
}

class _TechnicalGridPainter extends CustomPainter {
  final Color gridColor;
  final double gridSize;

  _TechnicalGridPainter({required this.gridColor, required this.gridSize});

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;

    // Draw vertical hairline grid lines
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }

    // Draw horizontal hairline grid lines
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TechnicalGridPainter oldDelegate) =>
      oldDelegate.gridColor != gridColor || oldDelegate.gridSize != gridSize;
}

/// Backwards-compatible backdrop alias supporting existing references.
class AnimatedGradientBackdrop extends StatelessWidget {
  final Widget child;
  final List<Color> colors;

  const AnimatedGradientBackdrop({super.key, required this.child, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.canvas,
      child: TechnicalGridBackdrop(child: child),
    );
  }
}
