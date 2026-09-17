import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class CropSelection {
  const CropSelection({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.selectedX,
    required this.selectedY,
    required this.cropX,
    required this.cropY,
    required this.cropWidth,
    required this.cropHeight,
  });
  final int sourceWidth, sourceHeight, selectedX, selectedY;
  final int cropX, cropY, cropWidth, cropHeight;
  Map<String, Object> toJson() => {
    'coordinateSpace': 'upright full-resolution image; zero-based pixels',
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
    'selectedX': selectedX,
    'selectedY': selectedY,
    'cropX': cropX,
    'cropY': cropY,
    'cropWidth': cropWidth,
    'cropHeight': cropHeight,
  };
}

class InspectionImage {
  const InspectionImage(
    this.originalPath,
    this.path,
    this.width,
    this.height, {
    this.cameraMetadata,
  });
  final String originalPath, path;
  final int width, height;
  final Map<String, Object?>? cameraMetadata;
}

class CropService {
  static CropSelection calculate({
    required int width,
    required int height,
    required double x,
    required double y,
  }) {
    if (width <= 0 || height <= 0 || !x.isFinite || !y.isFinite) {
      throw ArgumentError('Image dimensions and tap must be valid.');
    }
    final sx = x.floor().clamp(0, width - 1);
    final sy = y.floor().clamp(0, height - 1);
    final cw = math.min(512, width), ch = math.min(512, height);
    return CropSelection(
      sourceWidth: width,
      sourceHeight: height,
      selectedX: sx,
      selectedY: sy,
      cropX: (sx - cw ~/ 2).clamp(0, width - cw),
      cropY: (sy - ch ~/ 2).clamp(0, height - ch),
      cropWidth: cw,
      cropHeight: ch,
    );
  }

  static Future<InspectionImage> prepare(String path) =>
      compute(_prepare, path);
  static InspectionImage _prepare(String originalPath) {
    final decoded = img.decodeImage(File(originalPath).readAsBytesSync());
    if (decoded == null) {
      throw const FormatException('Cannot decode photograph.');
    }
    final cameraMetadata = _cameraMetadataFromExif(decoded);
    final upright = img.bakeOrientation(decoded);
    final path = '$originalPath.upright.png';
    File(path).writeAsBytesSync(img.encodePng(upright), flush: true);
    return InspectionImage(
      originalPath,
      path,
      upright.width,
      upright.height,
      cameraMetadata: cameraMetadata,
    );
  }

  static Map<String, Object?>? _cameraMetadataFromExif(img.Image image) {
    try {
      final exif = image.exif;
      final make = exif.imageIfd.make?.trim();
      final model = exif.imageIfd.model?.trim();
      final cameraModel = [make, model]
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .toSet()
          .join(' ');
      final focal35Value = exif.exifIfd[0xA405];
      // EXIF FocalLengthIn35mmFilm is an integer SHORT tag on iPhone images.
      final focal35 = focal35Value?.toInt().toDouble();
      final orientation = image.exif.imageIfd.orientation ?? 1;
      final swapsAxes = orientation >= 5 && orientation <= 8;
      final uprightWidth = swapsAxes ? image.height : image.width;
      final uprightHeight = swapsAxes ? image.width : image.height;
      final aspect = uprightWidth / uprightHeight;
      final sensorWidthEquivalent =
          43.2666 * aspect / math.sqrt(aspect * aspect + 1);
      final fov = focal35 != null && focal35 > 0
          ? 2 * math.atan(sensorWidthEquivalent / (2 * focal35)) * 180 / math.pi
          : null;
      if (cameraModel.isEmpty && fov == null) return null;
      return {
        if (cameraModel.isNotEmpty) 'cameraModel': cameraModel,
        if (fov != null && fov.isFinite) ...{
          'baseFovDegrees': fov,
          'correctedFovDegrees': fov,
        },
        if (focal35 != null && focal35 > 0)
          'focalLength35mm': focal35,
        'zoomFactor': 1.0,
        'metadataSource': 'EXIF',
        'formatWidth': uprightWidth,
        'formatHeight': uprightHeight,
      };
    } catch (_) {
      // EXIF is optional and often stripped by image-sharing services.
      return null;
    }
  }

  static Future<String> extract(
    InspectionImage source,
    CropSelection selection, {
    String? jobName,
    Map<String, Object?>? location,
    Map<String, Object?>? cameraMetadata,
    double? rangefinderDistanceMetres,
  }) => compute(_extract, (
    source,
    selection,
    jobName,
    location,
    cameraMetadata,
    rangefinderDistanceMetres,
  ));
  static String _extract(
    (
      InspectionImage,
      CropSelection,
      String?,
      Map<String, Object?>?,
      Map<String, Object?>?,
      double?,
    )
    request,
  ) {
    final (source, s, jobName, location, cameraMetadata, distanceMetres) =
        request;
    final decoded = img.decodePng(File(source.path).readAsBytesSync());
    if (decoded == null ||
        decoded.width != s.sourceWidth ||
        decoded.height != s.sourceHeight) {
      throw const FormatException('Source image dimensions do not match.');
    }
    final crop = img.copyCrop(
      decoded,
      x: s.cropX,
      y: s.cropY,
      width: s.cropWidth,
      height: s.cropHeight,
    );
    // One source photo represents one inspection record. Re-cropping it
    // replaces that record instead of appending another history item.
    final path = '${source.originalPath}.inspection.png';
    File(path).writeAsBytesSync(img.encodePng(crop), flush: true);
    for (final suffix in [
      '.accepted-mask.png',
      '.accepted.json',
      '.report.txt',
      '.report.json',
      '.report.csv',
      '.report.zip',
    ]) {
      try {
        File('$path$suffix').deleteSync();
      } on FileSystemException {
        // Sidecars are optional and may not exist yet.
      }
    }
    File('$path.json').writeAsStringSync(
      jsonEncode({
        ...s.toJson(),
        if (jobName case final name? when name.trim().isNotEmpty)
          'jobName': name.trim(),
        'originalPath': source.originalPath,
        'uprightPath': source.path,
        'cropPath': path,
        ...?location == null ? null : {'location': location},
        ...?cameraMetadata == null ? null : {'cameraMetadata': cameraMetadata},
        if (distanceMetres case final distance? when distance > 0)
          'rangefinderDistanceMetres': distance,
      }),
      flush: true,
    );
    return path;
  }
}
