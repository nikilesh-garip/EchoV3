import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ECHO - Neo-Brutalist Technical Grid / Swiss Editorial Design Tokens
///
/// High-contrast architectural layout inspired by Swiss typography, wireframe
/// fintech interfaces, and engineering telemetry. Off-white alabaster canvas,
/// stark 1px structural grid lines, Canary yellow accents, and zero-radius corners.
class AppColors {
  // Primary Canvas & Surface (Warm Off-White / Alabaster)
  static const canvas = Color(0xFFF7F7F4);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEFEFEA);
  static const surfaceDark = Color(0xFF0D0D0D); // Deep Onyx for inverse sections

  // Core Accent: Rich Golden Yellow / Canary Yellow
  static const primary = Color(0xFFFFD000);
  static const primaryHover = Color(0xFFFFDB33);
  static const primaryMuted = Color(0xFFFFF5C0);
  static const accent = Color(0xFFFFD000);

  // Structural Lines: Hairline Black / Charcoal (1px solid borders)
  static const line = Color(0xFF111111);
  static const lineSubtle = Color(0xFFDCDCD5);
  static const lineDark = Color(0xFF262626);

  // Text Hierarchy: Deep Ink Black & Muted Graphite
  static const ink = Color(0xFF0A0A0A);
  static const inkMuted = Color(0xFF5A5A5A);
  static const inkFaint = Color(0xFF8A8A8A);
  static const inkInverse = Color(0xFFF7F7F4);

  // Alert & Threat Palettes (Technical High-Contrast)
  static const danger = Color(0xFFE63946);
  static const dangerBg = Color(0xFFFFECEE);
  static const dangerSoft = Color(0xFFFFECEE);
  static const vermilion = Color(0xFFE63946);
  static const warning = Color(0xFFE76F51);
  static const warningBg = Color(0xFFFFF4ED);
  static const warningSoft = Color(0xFFFFF4ED);
  static const success = Color(0xFF10B981);
  static const successBg = Color(0xFFECFDF5);
  static const successSoft = Color(0xFFECFDF5);
  static const info = Color(0xFF2563EB);
  static const infoBg = Color(0xFFEFF6FF);
  static const infoSoft = Color(0xFFEFF6FF);

  static Color forRiskLevel(String level) {
    switch (level.toUpperCase()) {
      case 'HIGH_RISK':
        return danger;
      case 'POSSIBLE_DANGER':
        return warning;
      case 'SUSPICIOUS':
        return const Color(0xFFD97706);
      default:
        return const Color(0xFF111111);
    }
  }

  static Color softForRiskLevel(String level) {
    switch (level.toUpperCase()) {
      case 'HIGH_RISK':
        return dangerBg;
      case 'POSSIBLE_DANGER':
        return warningBg;
      case 'SUSPICIOUS':
        return const Color(0xFFFFFBEB);
      default:
        return primaryMuted;
    }
  }
}

class AppDurations {
  static const fast = Duration(milliseconds: 120);
  static const medium = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 400);
  static const pulse = Duration(milliseconds: 1800);
}

class AppRadii {
  // Refined Soft Neo-Brutalist design: subtle roundy corners (6-8px) on controls/buttons
  static const card = 8.0;
  static const control = 8.0;
  static const pill = 20.0;
}

/// Hard neo-brutalist offset shadow (no muddy blur, crisp architectural edge).
List<BoxShadow> neoShadow({double offset = 3, Color? color}) => [
      BoxShadow(
        color: color ?? AppColors.line,
        offset: Offset(offset, offset),
        blurRadius: 0,
      ),
    ];

/// Backwards-compatible softShadow helper redirected to clean technical offset.
List<BoxShadow> softShadow({double opacity = 1.0, double blur = 0, double y = 2}) => [
      BoxShadow(
        color: AppColors.line.withValues(alpha: 0.15),
        offset: Offset(y > 0 ? 2 : 0, y > 0 ? 2 : -2),
        blurRadius: 0,
      ),
    ];

class AppTheme {
  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    final scheme = ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: AppColors.ink,
      secondary: AppColors.line,
      onSecondary: AppColors.canvas,
      error: AppColors.danger,
      onError: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.apply(
        fontFamily: 'Roboto',
        bodyColor: AppColors.ink,
        displayColor: AppColors.ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.ink,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.ink,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.0,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
            side: const BorderSide(color: AppColors.line, width: 1.5),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.ink,
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          side: const BorderSide(color: AppColors.line, width: 1.2),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.ink,
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 13, letterSpacing: 0.2),
        labelStyle: TextStyle(color: AppColors.inkMuted, fontSize: 13, fontWeight: FontWeight.w600),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
          borderSide: BorderSide(color: AppColors.line, width: 1.2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
          borderSide: BorderSide(color: AppColors.line, width: 1.2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
          borderSide: BorderSide(color: AppColors.line, width: 2.2),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.ink : AppColors.inkMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.primary : AppColors.surfaceAlt,
        ),
        trackOutlineColor: WidgetStateProperty.all(AppColors.line),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.ink,
        inactiveTrackColor: AppColors.lineSubtle,
        thumbColor: AppColors.primary,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
        trackHeight: 3,
      ),
      dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.surface,
        side: const BorderSide(color: AppColors.line, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.control)),
        labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.ink,
        contentTextStyle: const TextStyle(color: AppColors.canvas, fontWeight: FontWeight.w700),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.control)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _FadeThroughTransitionBuilder(),
        TargetPlatform.iOS: _FadeThroughTransitionBuilder(),
      }),
    );
  }
}

class _FadeThroughTransitionBuilder extends PageTransitionsBuilder {
  const _FadeThroughTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}

/// Swiss editorial section label with index tracking.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  final String? index;
  const SectionLabel(this.text, {super.key, this.trailing, this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (index != null) ...[
                Text(
                  '$index // ',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
              Text(
                text.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Neo-Brutalist Technical Grid Card with 1px black border and optional hard offset shadow.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? background;
  final Color? borderColor;
  final double borderWidth;
  final VoidCallback? onTap;
  final bool hasShadow;
  final double shadowOffset;
  final bool isDark;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.background,
    this.borderColor,
    this.borderWidth = 1.0,
    this.onTap,
    this.hasShadow = false,
    this.shadowOffset = 3.0,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBg = isDark
        ? AppColors.surfaceDark
        : (background ?? AppColors.surface);
    final effectiveBorder = isDark
        ? AppColors.lineDark
        : (borderColor ?? AppColors.line);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: effectiveBorder, width: borderWidth),
        boxShadow: hasShadow ? neoShadow(offset: shadowOffset) : null,
      ),
      child: child,
    );

    if (onTap == null) return content;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// Refined technical tag with 1px border and smooth pill radius.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  final IconData? icon;
  final bool showBorder;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.icon,
    this.showBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: showBorder ? Border.all(color: color, width: 1.0) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
