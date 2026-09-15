import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powerline_measure/image_processing/image_coordinate_mapper.dart';

void main() {
  test('landscape letterbox and pan/zoom inverse', () {
    final mapper = ImageCoordinateMapper(
      sourceSize: const Size(4000, 3000),
      viewportSize: const Size(400, 800),
    );
    final controller = TransformationController();
    addTearDown(controller.dispose);
    expect(mapper.imageRect, const Rect.fromLTWH(0, 250, 400, 300));
    expect(
      mapper.viewportToSource(const Offset(200, 400), controller),
      const Offset(2000, 1500),
    );
    expect(mapper.viewportToSource(const Offset(200, 100), controller), isNull);
    controller.value = Matrix4.identity()
      ..setEntry(0, 0, 3)
      ..setEntry(1, 1, 3)
      ..setEntry(0, 3, -180)
      ..setEntry(1, 3, -700);
    expect(
      mapper.viewportToSource(const Offset(420, 500), controller)!.dx,
      closeTo(2000, 1e-8),
    );
    expect(
      mapper.viewportToSource(const Offset(420, 500), controller)!.dy,
      closeTo(1500, 1e-8),
    );
  });
  test('portrait image has horizontal letterboxing', () {
    final mapper = ImageCoordinateMapper(
      sourceSize: const Size(3000, 4000),
      viewportSize: const Size(800, 400),
    );
    final controller = TransformationController();
    addTearDown(controller.dispose);
    expect(mapper.imageRect, const Rect.fromLTWH(250, 0, 300, 400));
    expect(
      mapper.viewportToSource(const Offset(400, 200), controller),
      const Offset(1500, 2000),
    );
    expect(mapper.viewportToSource(const Offset(100, 200), controller), isNull);
  });
}
