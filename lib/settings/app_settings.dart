import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum MeasurementUnit { millimetres, inches }

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final instance = AppSettings._();

  MeasurementUnit unit = MeasurementUnit.millimetres;
  bool showCameraGrid = true;
  bool retainOriginalPhotos = true;
  bool useDarkTheme = true;
  double minimumConfidence = 0.5;
  double maskThreshold = 0.5;
  double maximumPointDistance = 32;

  Future<void> load() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final file = File('${documents.path}/.powerline-settings.json');
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      unit = raw['unit'] == 'inches'
          ? MeasurementUnit.inches
          : MeasurementUnit.millimetres;
      showCameraGrid = raw['showCameraGrid'] as bool? ?? true;
      retainOriginalPhotos = raw['retainOriginalPhotos'] as bool? ?? true;
      useDarkTheme = raw['useDarkTheme'] as bool? ?? true;
      minimumConfidence = _bounded(raw['minimumConfidence'], 0.5, 0, 1);
      maskThreshold = _bounded(raw['maskThreshold'], 0.5, 0.01, 1);
      maximumPointDistance = _bounded(raw['maximumPointDistance'], 32, 0, 512);
    } catch (_) {}
  }

  Future<void> save() async {
    final documents = await getApplicationDocumentsDirectory();
    await File('${documents.path}/.powerline-settings.json').writeAsString(
      jsonEncode({
        'unit': unit.name,
        'showCameraGrid': showCameraGrid,
        'retainOriginalPhotos': retainOriginalPhotos,
        'useDarkTheme': useDarkTheme,
        'minimumConfidence': minimumConfidence,
        'maskThreshold': maskThreshold,
        'maximumPointDistance': maximumPointDistance,
      }),
      flush: true,
    );
  }

  Future<void> setUnit(MeasurementUnit value) async {
    unit = value;
    notifyListeners();
    await save();
  }

  Future<void> setShowCameraGrid(bool value) async {
    showCameraGrid = value;
    notifyListeners();
    await save();
  }

  Future<void> setRetainOriginalPhotos(bool value) async {
    retainOriginalPhotos = value;
    notifyListeners();
    await save();
  }

  Future<void> setUseDarkTheme(bool value) async {
    useDarkTheme = value;
    notifyListeners();
    await save();
  }

  Future<void> setMinimumConfidence(double value) async {
    minimumConfidence = value;
    notifyListeners();
    await save();
  }

  Future<void> setMaskThreshold(double value) async {
    maskThreshold = value;
    notifyListeners();
    await save();
  }

  Future<void> setMaximumPointDistance(double value) async {
    maximumPointDistance = value;
    notifyListeners();
    await save();
  }

  static double _bounded(
    Object? value,
    double fallback,
    double min,
    double max,
  ) {
    final number = value is num ? value.toDouble() : fallback;
    return number.isFinite ? number.clamp(min, max) : fallback;
  }
}
