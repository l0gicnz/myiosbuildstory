import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'conductor_detection.dart';

class DetectionStore {
  static Future<void> save(
    String cropPath,
    ConductorDetectionResult result,
    Map<String, Object> cropMetadata, {
    ConductorDetection? selectedDetection,
  }) => compute(_save, (cropPath, result, cropMetadata, selectedDetection));
  static void _save(
    (String, ConductorDetectionResult, Map<String, Object>, ConductorDetection?)
    request,
  ) {
    final (cropPath, result, metadata, explicitSelection) = request;
    final selected = explicitSelection ?? result.selectedDetection;
    if (selected == null) throw StateError('No selected detection to accept.');
    final mask = img.Image(width: 512, height: 512, numChannels: 1);
    for (final pixel in mask) {
      pixel.r = selected.binaryMask[pixel.y * 512 + pixel.x] * 255;
    }
    final maskPath = '$cropPath.accepted-mask.png';
    File(maskPath).writeAsBytesSync(img.encodePng(mask), flush: true);
    File('$cropPath.accepted.json').writeAsStringSync(
      jsonEncode({
        ...metadata,
        'maskPath': maskPath,
        'confidence': selected.confidence,
        'classId': selected.classId,
        'maskArea': selected.maskArea,
        'segmentationWidthPx': selected.segmentationWidth,
        'selectedCropX': result.selectedPoint.dx,
        'selectedCropY': result.selectedPoint.dy,
        'boxXYXY': [
          selected.boundingBox.left,
          selected.boundingBox.top,
          selected.boundingBox.right,
          selected.boundingBox.bottom,
        ],
        'inferenceMilliseconds': result.inferenceTime.inMilliseconds,
        'acceptedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }
}
