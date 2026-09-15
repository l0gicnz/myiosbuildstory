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
    builder: (context, _) => MaterialApp(
      title: 'Powerline Measure',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: AppSettings.instance.useDarkTheme
            ? Brightness.dark
            : Brightness.light,
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    ),
  );
}
