import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'ui/home_page.dart';

/// Inko · Insta360 机型水印
///
/// Material 3 + 跟随系统的亮暗模式 + Android 12 以上的莫奈取色。
class InkoApp extends StatelessWidget {
  const InkoApp({super.key});

  /// 没有动态取色时的兜底种子色。
  static const Color _seed = Color(0xFF2F6BFF);

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final light =
            lightDynamic ??
            ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light);
        final dark =
            darkDynamic ??
            ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
        return MaterialApp(
          title: 'Inko',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: _decorate(light),
          darkTheme: _decorate(dark),
          home: const HomePage(),
        );
      },
    );
  }

  ThemeData _decorate(ColorScheme scheme) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
