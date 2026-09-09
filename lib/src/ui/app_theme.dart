import 'package:flutter/material.dart';

/// Builds the minimalist app theme.
///
/// The palette is intentionally restrained: neutral surfaces, a single
/// calm accent color, and soft dividers to keep the UI uncluttered.
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final dividerColor =
      (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4A6FA5),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: isDark
        ? const Color(0xFF161616)
        : const Color(0xFFFAFAFA),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? const Color(0xFF242424) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: dividerColor),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dividerColor,
      thickness: 1,
      space: 1,
    ),
    visualDensity: VisualDensity.standard,
  );
}
