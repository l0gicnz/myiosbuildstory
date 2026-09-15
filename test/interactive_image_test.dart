import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:powerline_measure/image_processing/crop_service.dart';
import 'package:powerline_measure/inspection/interactive_image.dart';

void main() {
  testWidgets('tap after zoom/pan maps correctly and drag does not select', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('powerline_widget_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/source.png');
    file.writeAsBytesSync(img.encodePng(img.Image(width: 800, height: 600)));
    final points = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: InteractiveImage(
                source: InspectionImage(file.path, file.path, 800, 600),
                onSelect: points.add,
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(InteractiveImage));
    await tester.tapAt(origin + const Offset(200, 200));
    expect(points.single, const Offset(400, 300));
    await tester.tapAt(origin + const Offset(10, 10));
    expect(points.length, 1);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    viewer.transformationController!.value = Matrix4.identity()
      ..setEntry(0, 0, 2)
      ..setEntry(1, 1, 2)
      ..setEntry(0, 3, -100)
      ..setEntry(1, 3, -100);
    await tester.pump();
    await tester.tapAt(origin + const Offset(200, 200));
    expect(points.last, const Offset(300, 200));
    await tester.dragFrom(
      origin + const Offset(200, 200),
      const Offset(40, 40),
    );
    await tester.pump();
    expect(points.length, 2);
    await tester.pumpWidget(const SizedBox());
    imageCache.clear();
    imageCache.clearLiveImages();
  });
}
