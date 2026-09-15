import 'dart:io';

import 'package:camera/camera.dart';
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
}
