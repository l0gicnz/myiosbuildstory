import 'dart:io';

import 'package:flutter/material.dart';

import '../image_processing/crop_service.dart';
import '../image_processing/image_coordinate_mapper.dart';

class InteractiveImage extends StatefulWidget {
  const InteractiveImage({
    super.key,
    required this.source,
    required this.onSelect,
    this.selection,
    this.calibrating = false,
    this.calibrationPoints = const [],
    this.onCalibrationTap,
  });
  final InspectionImage source;
  final CropSelection? selection;
  final ValueChanged<Offset> onSelect;
  final bool calibrating;
  final List<Offset> calibrationPoints;
  final ValueChanged<Offset>? onCalibrationTap;
  @override
  State<InteractiveImage> createState() => _InteractiveImageState();
}

class _InteractiveImageState extends State<InteractiveImage> {
  final _transform = TransformationController();
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mapper = ImageCoordinateMapper(
        sourceSize: Size(
          widget.source.width.toDouble(),
          widget.source.height.toDouble(),
        ),
        viewportSize: constraints.biggest,
      );
      return Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final point = mapper.viewportToSource(
                details.localPosition,
                _transform,
              );
              if (point != null) {
                if (widget.calibrating && widget.onCalibrationTap != null) {
                  widget.onCalibrationTap!(point);
                } else {
                  widget.onSelect(point);
                }
              }
            },
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 32,
              child: SizedBox.fromSize(
                size: constraints.biggest,
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: mapper.imageRect,
                      child: Image.file(
                        File(widget.source.path),
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, error, stack) =>
                            Center(child: Text('Cannot display photo: $error')),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _transform,
                          builder: (_, _) => CustomPaint(
                            painter: _SelectionPainter(
                              mapper,
                              widget.selection,
                              _transform.value.getMaxScaleOnAxis(),
                              widget.calibrationPoints,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton.filledTonal(
              tooltip: 'Reset zoom',
              onPressed: () => _transform.value = Matrix4.identity(),
              icon: const Icon(Icons.fit_screen),
            ),
          ),
        ],
      );
    },
  );
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(
    this.mapper,
    this.selection,
    this.zoom,
    this.calibrationPoints,
  );
  final ImageCoordinateMapper mapper;
  final CropSelection? selection;
  final double zoom;
  final List<Offset> calibrationPoints;
  @override
  void paint(Canvas canvas, Size size) {
    final s = selection;
    if (s == null) {
      _paintCalibrationPoints(canvas);
      return;
    }
    final rect = Rect.fromLTWH(
      mapper.sourceToScene(Offset(s.cropX.toDouble(), s.cropY.toDouble())).dx,
      mapper.sourceToScene(Offset(s.cropX.toDouble(), s.cropY.toDouble())).dy,
      s.cropWidth * mapper.scale,
      s.cropHeight * mapper.scale,
    );
    canvas.drawRect(
      rect,
      Paint()..color = Colors.amber.withValues(alpha: 0.15),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / zoom,
    );
    final point = mapper.sourceToScene(
      Offset(s.selectedX + 0.5, s.selectedY + 0.5),
    );
    canvas.drawCircle(
      point,
      7 / zoom,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 / zoom,
    );
    canvas.drawCircle(
      point,
      7 / zoom,
      Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / zoom,
    );
    canvas.drawCircle(point, 2 / zoom, Paint()..color = Colors.cyanAccent);
    _paintCalibrationPoints(canvas);
  }

  void _paintCalibrationPoints(Canvas canvas) {
    for (var i = 0; i < calibrationPoints.length; i++) {
      final calibrationPoint = mapper.sourceToScene(calibrationPoints[i]);
      final color = i == 0 ? Colors.amberAccent : Colors.pinkAccent;
      canvas.drawCircle(
        calibrationPoint,
        10 / zoom,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 / zoom,
      );
      canvas.drawCircle(
        calibrationPoint,
        10 / zoom,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / zoom,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) => true;
}
