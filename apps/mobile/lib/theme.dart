import 'package:flutter/material.dart';

/// Colours used across the phone app.
class Palette {
  static const bg = Color(0xFF07090F);
  static const surface = Color(0xFF10141F);
  static const surfaceHi = Color(0xFF171C2B);
  static const outline = Color(0x1AFFFFFF);
  static const text = Color(0xFFF3F5FB);
  static const textDim = Color(0xFF8E97AE);
  static const blue = Color(0xFF3B82F6);
  static const violet = Color(0xFF8B5CF6);
  static const green = Color(0xFF22C55E);
  static const amber = Color(0xFFF5A524);
  static const red = Color(0xFFEF4444);

  static const brand = LinearGradient(
    colors: [blue, violet],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const live = LinearGradient(
    colors: [Color(0xFF22C55E), Color(0xFF14B8A6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const stop = LinearGradient(
    colors: [Color(0xFF2A2F42), Color(0xFF222737)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.blue,
    brightness: Brightness.dark,
  ).copyWith(
    surface: Palette.bg,
    primary: Palette.blue,
    secondary: Palette.violet,
    onSurface: Palette.text,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: Palette.bg,
    textTheme: base.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
    splashFactory: InkSparkle.splashFactory,
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: Palette.blue,
      inactiveTrackColor: const Color(0x22FFFFFF),
      thumbColor: Colors.white,
      overlayColor: Palette.blue.withValues(alpha: 0.18),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
      disabledThumbColor: const Color(0x55FFFFFF),
      disabledActiveTrackColor: const Color(0x22FFFFFF),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Palette.surfaceHi,
      contentTextStyle: const TextStyle(color: Palette.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Palette.surfaceHi,
      labelStyle: const TextStyle(color: Palette.textDim),
      hintStyle: const TextStyle(color: Color(0x55FFFFFF)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Palette.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Palette.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Palette.blue, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
  );
}
