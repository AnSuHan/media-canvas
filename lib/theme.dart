import 'package:flutter/material.dart';

/// "Editing console" palette — a warm espresso workspace with brass accents,
/// chosen to avoid the generic near-black + acid-green look.
class AppColors {
  static const base = Color(0xFF1A1816); // espresso workspace
  static const baseHi = Color(0xFF201D1A); // canvas, a hair lighter
  static const panel = Color(0xFF252220); // top bar / docks
  static const panelHi = Color(0xFF2E2A27); // raised controls
  static const well = Color(0xFF0E0D0C); // media background well
  static const line = Color(0xFF3A3530); // hairlines
  static const brass = Color(0xFFC9A24B); // accent (editing-suite metal)
  static const brassDim = Color(0xFF8C7237);
  static const text = Color(0xFFE8E3DB); // warm off-white
  static const textDim = Color(0xFF9A938A); // secondary
  static const danger = Color(0xFFD98C6A); // terracotta-ish error
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.base,
    fontFamily: 'Roboto',
  );
  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary: AppColors.brass,
      secondary: AppColors.brass,
      surface: AppColors.panel,
      onSurface: AppColors.text,
      error: AppColors.danger,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.panelHi,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.brass,
      inactiveTrackColor: AppColors.line,
      thumbColor: AppColors.brass,
    ),
    iconTheme: const IconThemeData(color: AppColors.text),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
  );
}

/// Uppercase micro-label used throughout the console UI.
class MicroLabel extends StatelessWidget {
  const MicroLabel(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: color ?? AppColors.textDim,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
      ),
    );
  }
}
