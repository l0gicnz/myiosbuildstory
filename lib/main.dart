import 'package:flutter/material.dart';

import 'camera/camera_screen.dart';
import 'settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  runApp(const PowerlineMeasureApp());
}

class PowerlineMeasureApp extends StatelessWidget {
  const PowerlineMeasureApp({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: AppSettings.instance,
    builder: (context, _) {
      final dark = AppSettings.instance.useDarkTheme;
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF5AD0AA),
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      return MaterialApp(
        title: 'Powerline Measure',
        theme: ThemeData(
          colorScheme: scheme,
          brightness: dark ? Brightness.dark : Brightness.light,
          scaffoldBackgroundColor: dark
              ? const Color(0xFF0D1112)
              : scheme.surface,
          cardColor: dark ? const Color(0xFF1B2021) : scheme.surfaceContainer,
          useMaterial3: true,
          appBarTheme: AppBarTheme(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            titleTextStyle: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: dark ? const Color(0xFFF2F4F3) : scheme.onSurface,
            ),
          ),
          textTheme: ThemeData().textTheme.apply(
            bodyColor: dark ? const Color(0xFFE7E9E8) : scheme.onSurface,
            displayColor: dark ? const Color(0xFFF2F4F3) : scheme.onSurface,
          ),
          cardTheme: CardThemeData(
            color: dark ? const Color(0xFF1B2021) : scheme.surfaceContainer,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF9AE2CC),
              foregroundColor: const Color(0xFF073B31),
              minimumSize: const Size(0, 58),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              textStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        home: const CameraScreen(),
      );
    },
  );
}
