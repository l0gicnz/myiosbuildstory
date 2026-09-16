import 'dart:typed_data';
import 'dart:ui';
import 'dart:math' as math;

class ConductorDetection {
  const ConductorDetection({
    required this.index,
    required this.confidence,
    required this.boundingBox,
    required this.binaryMask,
    required this.maskArea,
    required this.distanceFromSelectedPoint,
    required this.containsSelectedPoint,
    this.classId,
    this.rejectionReasons = const [],
  });
  final int index, maskArea;
  final int? classId;
  final double confidence, distanceFromSelectedPoint;
  final Rect boundingBox;
  final Uint8List binaryMask;
  final bool containsSelectedPoint;
  final List<String> rejectionReasons;
  bool get isValid => rejectionReasons.isEmpty;

  /// Foreground thickness in pixels, measured perpendicular to the mask's
  /// principal (long) axis. Horizontal span measures wire length for a
  /// horizontally framed conductor and is not its physical diameter.
  double get segmentationThicknessPixels {
    var count = 0;
    var meanX = 0.0, meanY = 0.0;
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        if (binaryMask[y * 512 + x] == 0) continue;
        count++;
        meanX += x + 0.5;
        meanY += y + 0.5;
      }
    }
    if (count == 0) return 0;
    meanX /= count;
    meanY /= count;

    var xx = 0.0, yy = 0.0, xy = 0.0;
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        if (binaryMask[y * 512 + x] == 0) continue;
        final dx = x + 0.5 - meanX;
        final dy = y + 0.5 - meanY;
        xx += dx * dx;
        yy += dy * dy;
        xy += dx * dy;
      }
    }
    // Eigenvector for the major PCA axis; its perpendicular gives thickness.
    final angle = 0.5 * math.atan2(2 * xy, xx - yy);
    final normalX = -math.sin(angle), normalY = math.cos(angle);
    var minProjection = double.infinity;
    var maxProjection = double.negativeInfinity;
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        if (binaryMask[y * 512 + x] == 0) continue;
        final projection = (x + 0.5 - meanX) * normalX +
            (y + 0.5 - meanY) * normalY;
        minProjection = math.min(minProjection, projection);
        maxProjection = math.max(maxProjection, projection);
      }
    }
    return maxProjection - minProjection + 1;
  }
}

class ConductorDetectionResult {
  const ConductorDetectionResult({
    required this.detections,
    required this.selectedDetection,
    required this.inferenceTime,
    required this.totalTime,
    required this.selectedPoint,
  });

  /// Includes rejected detections and their reasons for development inspection.
  final List<ConductorDetection> detections;
  final ConductorDetection? selectedDetection;
  final Duration inferenceTime, totalTime;
  final Offset selectedPoint;
}

class ModelTensor {
  const ModelTensor(this.shape, this.values, this.type);
  final List<int> shape;
  final List<num> values;
  final String type;
  void validate() {
    if (shape.any((d) => d < 0) ||
        shape.fold(1, (a, b) => a * b) != values.length) {
      throw FormatException(
        'Invalid tensor shape $shape for ${values.length} values.',
      );
    }
  }
}
