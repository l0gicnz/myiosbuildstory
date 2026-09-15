import 'package:flutter/material.dart';

import 'camera/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PowerlineMeasureApp());
}

class PowerlineMeasureApp extends StatelessWidget {
  const PowerlineMeasureApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Powerline Measure',
    theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
    home: const CameraScreen(),
  );
}
