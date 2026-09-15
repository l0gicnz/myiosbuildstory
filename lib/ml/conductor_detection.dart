import 'dart:typed_data';
import 'dart:ui';

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

  /// Horizontal pixel span of the segmented foreground, inclusive.
  /// This describes the mask itself and is independent of the model box.
  int get segmentationWidth {
    var left = binaryMask.length;
    var right = -1;
    for (var y = 0; y < 512; y++) {
      for (var x = 0; x < 512; x++) {
        if (binaryMask[y * 512 + x] == 0) continue;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
    return right < left ? 0 : right - left + 1;
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
