import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'conductor_detection.dart';

class DetectionSelector {
  static Offset cropRelativePoint({
    required int selectedX,
    required int selectedY,
    required int cropX,
    required int cropY,
  }) => Offset((selectedX - cropX).toDouble(), (selectedY - cropY).toDouble());

  static void validatePoint(Offset point, int width, int height) {
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dy < 0 ||
        point.dx >= width ||
        point.dy >= height) {
      throw ArgumentError('Selected point is outside the crop.');
    }
  }

  /// Distance to the nearest foreground pixel (not an unrelated nearby box).
  static ({bool contains, double distance}) proximity(
    Uint8List mask,
    int width,
    Offset point,
  ) {
    if (width <= 0 || mask.length % width != 0) {
      throw ArgumentError('Invalid mask dimensions.');
    }
    validatePoint(point, width, mask.length ~/ width);
    final contains = mask[point.dy.floor() * width + point.dx.floor()] != 0;
    if (contains) return (contains: true, distance: 0);
    var distanceSquared = double.infinity;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0) continue;
      final dx = (i % width) - point.dx, dy = (i ~/ width) - point.dy;
      distanceSquared = math.min(distanceSquared, dx * dx + dy * dy);
    }
    return (contains: false, distance: math.sqrt(distanceSquared));
  }

  static ConductorDetection? select(
    List<ConductorDetection> detections,
    double maximumDistance,
  ) {
    final candidates = detections
        .where(
          (d) => d.isValid && d.distanceFromSelectedPoint <= maximumDistance,
        )
        .toList();
    candidates.sort((a, b) {
      if (a.containsSelectedPoint != b.containsSelectedPoint) {
        return a.containsSelectedPoint ? -1 : 1;
      }
      if (!a.containsSelectedPoint) {
        final distance = a.distanceFromSelectedPoint.compareTo(
          b.distanceFromSelectedPoint,
        );
        if (distance != 0) return distance;
      }
      final confidence = b.confidence.compareTo(a.confidence);
      return confidence != 0 ? confidence : a.index.compareTo(b.index);
    });
    return candidates.isEmpty ? null : candidates.first;
  }
}
