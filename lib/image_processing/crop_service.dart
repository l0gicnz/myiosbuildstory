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
  const InspectionImage(this.originalPath, this.path, this.width, this.height);
  final String originalPath, path;
  final int width, height;
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
    final upright = img.bakeOrientation(decoded);
    final path = '$originalPath.upright.png';
    File(path).writeAsBytesSync(img.encodePng(upright), flush: true);
    return InspectionImage(originalPath, path, upright.width, upright.height);
  }

  static Future<String> extract(
    InspectionImage source,
    CropSelection selection,
  ) => compute(_extract, (source, selection));
  static String _extract((InspectionImage, CropSelection) request) {
    final (source, s) = request;
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
    final path =
        '${source.originalPath}.crop_${DateTime.now().microsecondsSinceEpoch}.png';
    File(path).writeAsBytesSync(img.encodePng(crop), flush: true);
    File('$path.json').writeAsStringSync(
      jsonEncode({
        ...s.toJson(),
        'originalPath': source.originalPath,
        'uprightPath': source.path,
        'cropPath': path,
      }),
      flush: true,
    );
    return path;
  }
}
