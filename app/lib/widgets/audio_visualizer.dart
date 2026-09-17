import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Live microphone visualiser with Swiss technical oscillograph aesthetic.
///
/// Draws the amplitude envelope in a hard-edged, technical wireframe grid with
/// square bars, crosshair markers, and zero rounded corners.
class LiveWaveform extends StatefulWidget {
  final double amplitude; // 0..1, latest microphone level
  final bool active;
  final Color color;
  final double height;
  final String? overlayLabel;

  const LiveWaveform({
    super.key,
    required this.amplitude,
    required this.active,
    this.color = AppColors.primary,
    this.height = 150,
    this.overlayLabel,
  });

  @override
  State<LiveWaveform> createState() => _LiveWaveformState();
}

class _LiveWaveformState extends State<LiveWaveform> with SingleTickerProviderStateMixin {
  static const _barCount = 56;

  late final AnimationController _controller;
  final List<double> _levels = List<double>.filled(_barCount, 0.0, growable: true);
  double _smoothed = 0.0;
  double _phase = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
    _controller.addListener(_onFrame);
  }

  void _onFrame() {
    final target = widget.active ? widget.amplitude.clamp(0.0, 1.0) : 0.0;
    _smoothed += (target - _smoothed) * (target > _smoothed ? 0.45 : 0.12);
    _phase += 0.06;

    _levels.removeAt(0);
    if (widget.active) {
      _levels.add(_smoothed);
    } else {
      _levels.add(0.045 + 0.03 * (0.5 + 0.5 * math.sin(_phase)));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onFrame);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppColors.line, width: 1.2),
        boxShadow: neoShadow(offset: 3),
      ),
      child: Stack(
        children: [
          // Background technical grid markers
          Positioned.fill(
            child: CustomPaint(
              painter: _TechnicalGridPainter(),
            ),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _WaveformPainter(
                  levels: List<double>.from(_levels),
                  color: widget.color,
                  active: widget.active,
                  phase: _phase,
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 10,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  color: widget.active ? AppColors.ink : AppColors.inkFaint,
                ),
                const SizedBox(width: 6),
                Text(
                  (widget.overlayLabel ?? 'LIVE // 16kHz BUFFER').toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                    color: widget.active ? AppColors.ink : AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            top: 10,
            child: Text(
              '${(widget.amplitude * 100).clamp(0, 100).toStringAsFixed(0)}% SIG',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TechnicalGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.lineSubtle
      ..strokeWidth = 1.0;

    // Horizontal grid guidelines
    canvas.drawLine(Offset(0, size.height * 0.25), Offset(size.width, size.height * 0.25), p);
    canvas.drawLine(Offset(0, size.height * 0.75), Offset(size.width, size.height * 0.75), p);

    // Corner crosshair markers
    final markerPaint = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1.5;

    // Top-left
    canvas.drawLine(const Offset(4, 4), const Offset(12, 4), markerPaint);
    canvas.drawLine(const Offset(4, 4), const Offset(4, 12), markerPaint);
    // Bottom-right
    canvas.drawLine(Offset(size.width - 4, size.height - 4), Offset(size.width - 12, size.height - 4), markerPaint);
    canvas.drawLine(Offset(size.width - 4, size.height - 4), Offset(size.width - 4, size.height - 12), markerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _WaveformPainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  final bool active;
  final double phase;

  _WaveformPainter({
    required this.levels,
    required this.color,
    required this.active,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final barWidth = size.width / levels.length;
    final maxBar = size.height * 0.40;

    // Centre hairline baseline
    final baseline = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), baseline);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final height = math.max(2.0, level * maxBar);
      final x = i * barWidth + barWidth * 0.2;
      final w = math.max(2.0, barWidth * 0.6);

      // Neo-brutalist square bar with Canary yellow fill and black 1px border
      final barRect = Rect.fromLTWH(x, midY - height, w, height * 2);

      final fillPaint = Paint()
        ..color = active
            ? (level > 0.6 ? AppColors.danger : AppColors.primary)
            : AppColors.surfaceAlt;
      canvas.drawRect(barRect, fillPaint);

      final borderPaint = Paint()
        ..color = AppColors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawRect(barRect, borderPaint);
    }

    if (!active) return;

    // Leading-edge cursor at the newest sample
    final headX = size.width - barWidth;
    final cursorPaint = Paint()
      ..color = AppColors.ink
      ..strokeWidth = 2.0;
    canvas.drawLine(Offset(headX, midY - maxBar), Offset(headX, midY + maxBar), cursorPaint);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}

/// Architectural square technical radar pulse.
class PulseRing extends StatefulWidget {
  final bool active;
  final Color color;
  final double size;
  final Widget child;

  const PulseRing({
    super.key,
    required this.active,
    required this.child,
    this.color = AppColors.primary,
    this.size = 168,
  });

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.pulse,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _PulsePainter(
              progress: _controller.value,
              color: widget.color,
              active: widget.active,
            ),
            child: Center(child: child),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool active;

  _PulsePainter({required this.progress, required this.color, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width * 0.32;

    // Hard technical center square
    final baseRect = Rect.fromCenter(center: center, width: baseRadius * 2, height: baseRadius * 2);
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.line;
    canvas.drawRect(baseRect, boxPaint);

    if (!active) return;

    // Expanding architectural frames
    for (var i = 0; i < 2; i++) {
      final t = (progress + i / 2) % 1.0;
      final currentDim = baseRadius * 2 + t * (size.width - baseRadius * 2);
      final r = Rect.fromCenter(center: center, width: currentDim, height: currentDim);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = AppColors.line.withValues(alpha: (1 - t) * 0.7);
      canvas.drawRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.active != active;
}

/// Swiss technical square gauge meter.
class RiskGauge extends StatelessWidget {
  final int score;
  final String level;
  final double size;

  const RiskGauge({super.key, required this.score, required this.level, this.size = 132});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forRiskLevel(level);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: score.clamp(0, 100) / 100),
      duration: AppDurations.slow,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.line, width: 1.5),
            boxShadow: neoShadow(offset: 3),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${(value * 100).round()}',
                style: TextStyle(
                  fontSize: size * 0.30,
                  fontWeight: FontWeight.w900,
                  color: color,
                  height: 1,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: color == AppColors.line ? AppColors.surfaceAlt : color,
                child: Text(
                  level.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w900,
                    color: color == AppColors.line ? AppColors.ink : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Hard-edged Neo-brutalist Countdown Timer.
class CountdownRing extends StatelessWidget {
  final double remainingSeconds;
  final double totalSeconds;
  final double size;

  const CountdownRing({
    super.key,
    required this.remainingSeconds,
    required this.totalSeconds,
    this.size = 108,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = totalSeconds <= 0 ? 0.0 : (remainingSeconds / totalSeconds).clamp(0.0, 1.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line, width: 2.0),
        boxShadow: neoShadow(offset: 4, color: AppColors.danger),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                remainingSeconds.ceil().toString().padLeft(2, '0'),
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  color: AppColors.danger,
                  height: 1,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'SEC // CANCEL',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 4,
              color: AppColors.surfaceAlt,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: Container(color: AppColors.danger),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
