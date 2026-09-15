import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

class CameraService {
  Future<CameraController> open() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('No camera is available.');
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      return controller;
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
  }

  Future<String> capture(CameraController controller) async {
    final photo = await controller.takePicture();
    final documents = await getApplicationDocumentsDirectory();
    final directory = await Directory('${documents.path}/captures')
        .create(recursive: true);
    final path =
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}_${photo.name}';
    await photo.saveTo(path);
    return path;
  }

  Future<String> importImage(String sourcePath) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = await Directory('${documents.path}/captures')
        .create(recursive: true);
    final source = File(sourcePath);
    final extension = sourcePath.contains('.')
        ? sourcePath.substring(sourcePath.lastIndexOf('.'))
        : '.image';
    final destination =
        '${directory.path}/${DateTime.now().microsecondsSinceEpoch}$extension';
    await source.copy(destination);
    return destination;
  }

  /// Returns a JSON-safe snapshot of the phone's location, or null when the
  /// user declines access or location services are unavailable.
  Future<Map<String, Object?>?> currentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracyMetres': position.accuracy,
        'altitudeMetres': position.altitude,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      };
    } on TimeoutException {
      return null;
    } on LocationServiceDisabledException {
      return null;
    } on PermissionDeniedException {
      return null;
    }
  }
}
