import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';

/// Sign-in shell styled in Swiss Editorial / Neo-Brutalist Technical Grid.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  late final AnimationController _logoController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _identifierController.dispose();
    _nameController.dispose();
    _passwordController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    await AppSession.instance.signIn(
      identifier: _identifierController.text,
      displayName: _nameController.text,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: TechnicalGridBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FadeSlideIn(index: 0, child: _buildLogo()),
                      const SizedBox(height: 20),
                      FadeSlideIn(
                        index: 1,
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(AppRadii.control),
                                border: Border.all(color: AppColors.line, width: 1),
                              ),
                              child: const Text(
                                'ACOUSTIC SAFETY TELEMETRY',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                  color: AppColors.ink,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'ECHO',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 44,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 10,
                                color: AppColors.ink,
                                height: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      const FadeSlideIn(
                        index: 2,
                        child: Text(
                          'Acoustic hazard detection that calls the people who can help.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppColors.inkMuted, height: 1.4),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FadeSlideIn(
                        index: 3,
                        child: AppCard(
                          hasShadow: true,
                          shadowOffset: 4,
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'AUTHENTICATION',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceAlt,
                                      borderRadius: BorderRadius.circular(AppRadii.control),
                                    ),
                                    child: const Text(
                                      'LOCAL // DEMO',
                                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Identity is stored on this device only.',
                                style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                              ),
                              const SizedBox(height: 20),
                              TextFormField(
                                controller: _identifierController,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'EMAIL OR PHONE',
                                  prefixIcon: Icon(Icons.alternate_email, size: 18, color: AppColors.ink),
                                ),
                                validator: (value) => (value == null || value.trim().isEmpty)
                                    ? 'Enter an email or phone number'
                                    : null,
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _nameController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'DISPLAY NAME (OPTIONAL)',
                                  helperText: 'Spoken in emergency alert dispatch',
                                  helperStyle: TextStyle(fontSize: 10, color: AppColors.inkMuted),
                                  prefixIcon: Icon(Icons.badge_outlined, size: 18, color: AppColors.ink),
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: _obscure,
                                onFieldSubmitted: (_) => _submit(),
                                decoration: InputDecoration(
                                  labelText: 'PASSWORD',
                                  prefixIcon: const Icon(Icons.lock_outline, size: 18, color: AppColors.ink),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                      size: 18,
                                      color: AppColors.ink,
                                    ),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                validator: (value) => (value == null || value.isEmpty)
                                    ? 'Enter any password'
                                    : null,
                              ),
                              const SizedBox(height: 24),
                              PressableScale(
                                child: ElevatedButton(
                                  onPressed: _busy ? null : _submit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    foregroundColor: AppColors.ink,
                                    side: const BorderSide(color: AppColors.line, width: 1.5),
                                  ),
                                  child: _busy
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppColors.ink,
                                          ),
                                        )
                                      : const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text('ENTER SYSTEM'),
                                            SizedBox(width: 8),
                                            Icon(Icons.arrow_forward, size: 16, color: AppColors.ink),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FadeSlideIn(
                        index: 4,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(AppRadii.control),
                            border: Border.all(color: AppColors.line, width: 1),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Icon(Icons.info_outline, size: 16, color: AppColors.ink),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Demo sign-in: any credentials are accepted and nothing is sent anywhere. '
                                  'This scopes contacts, history, and alerts locally.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: AppColors.inkMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return SizedBox(
      height: 100,
      child: AnimatedBuilder(
        animation: _logoController,
        builder: (context, _) => CustomPaint(
          painter: _LogoPainter(_logoController.value),
          child: const Center(
            child: Icon(Icons.graphic_eq_rounded, size: 36, color: AppColors.ink),
          ),
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  final double t;
  _LogoPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Center yellow badge
    final centerDim = 46.0 + 2.0 * math.sin(t * 2 * math.pi);
    final centerRect = Rect.fromCenter(center: center, width: centerDim, height: centerDim);
    final centerRRect = RRect.fromRectAndRadius(centerRect, const Radius.circular(8));
    canvas.drawRRect(
      centerRRect,
      Paint()..color = AppColors.primary,
    );
    canvas.drawRRect(
      centerRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.line,
    );

    // Expanding architectural frames
    for (var i = 0; i < 2; i++) {
      final phase = (t + i / 2) % 1.0;
      final dim = 54.0 + phase * 36.0;
      final r = Rect.fromCenter(center: center, width: dim, height: dim);
      final rrect = RRect.fromRectAndRadius(r, const Radius.circular(10));
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = AppColors.line.withValues(alpha: (1 - phase) * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) => oldDelegate.t != t;
}
