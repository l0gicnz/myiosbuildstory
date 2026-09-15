import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fit the upright source into a scene, then invert the viewer's pan/zoom.
class ImageCoordinateMapper {
  ImageCoordinateMapper({required this.sourceSize, required this.viewportSize});
  final Size sourceSize, viewportSize;
  double get scale => math.min(
    viewportSize.width / sourceSize.width,
    viewportSize.height / sourceSize.height,
  );
  Rect get imageRect => Rect.fromLTWH(
    (viewportSize.width - sourceSize.width * scale) / 2,
    (viewportSize.height - sourceSize.height * scale) / 2,
    sourceSize.width * scale,
    sourceSize.height * scale,
  );

  Offset? viewportToSource(Offset point, TransformationController transform) {
    final scene = transform.toScene(point);
    if (!imageRect.contains(scene)) return null;
    return (scene - imageRect.topLeft) / scale;
  }

  Offset sourceToScene(Offset point) => imageRect.topLeft + point * scale;
}
