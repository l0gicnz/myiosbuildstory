import 'package:flutter/material.dart';

import '../ml/conductor_detection.dart';

class ConductorOverlay extends StatefulWidget {
  const ConductorOverlay({
    super.key,
    required this.result,
    this.selectedDetection,
    required this.point,
    required this.showAll,
    required this.width,
    required this.height,
  });
  final ConductorDetectionResult? result;
  final ConductorDetection? selectedDetection;
  final Offset point;
  final bool showAll;
  final int width, height;
  @override
  State<ConductorOverlay> createState() => _ConductorOverlayState();
}

class _ConductorOverlayState extends State<ConductorOverlay> {
  Map<int, Path> _paths = {};
  @override
  void initState() {
    super.initState();
    _rebuildPaths();
  }

  @override
  void didUpdateWidget(covariant ConductorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) _rebuildPaths();
  }

  void _rebuildPaths() {
    _paths = {};
    for (final detection
        in widget.result?.detections ?? <ConductorDetection>[]) {
      final path = Path();
      // Horizontal runs preserve exact pixel edges and avoid one draw per pixel.
      for (var y = 0; y < widget.height; y++) {
        var x = 0;
        while (x < widget.width) {
          if (detection.binaryMask[y * widget.width + x] == 0) {
            x++;
            continue;
          }
          final start = x;
          while (x < widget.width &&
              detection.binaryMask[y * widget.width + x] != 0) {
            x++;
          }
          path.addRect(
            Rect.fromLTWH(
              start.toDouble(),
              y.toDouble(),
              (x - start).toDouble(),
              1,
            ),
          );
        }
      }
      _paths[detection.index] = path;
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _OverlayPainter(
        widget.result,
        widget.selectedDetection,
        widget.point,
        widget.showAll,
        widget.width,
        widget.height,
        _paths,
      ),
    ),
  );
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(
    this.result,
    this.selectedDetection,
    this.point,
    this.showAll,
    this.width,
    this.height,
    this.paths,
  );
  final ConductorDetectionResult? result;
  final ConductorDetection? selectedDetection;
  final Offset point;
  final bool showAll;
  final int width, height;
  final Map<int, Path> paths;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / width, size.height / height);
    canvas.clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    final selected = selectedDetection ?? result?.selectedDetection;
    for (final d in result?.detections ?? <ConductorDetection>[]) {
      if (!showAll && d != selected) continue;
      final color = d == selected
          ? Colors.greenAccent
          : d.isValid
          ? Colors.orange
          : Colors.redAccent;
      canvas.drawPath(
        paths[d.index]!,
        Paint()
          ..color = color.withValues(alpha: 0.4)
          ..isAntiAlias = false,
      );
      if (showAll) {
        final text = TextPainter(
          text: TextSpan(
            text: '#${d.index} ${(d.confidence * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 12,
              color: color,
              backgroundColor: Colors.black87,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          Offset(
            d.boundingBox.left.clamp(0, width - text.width).toDouble(),
            d.boundingBox.top.clamp(0, height - text.height).toDouble(),
          ),
        );
      }
    }
    final centre = point + const Offset(0.5, 0.5);
    canvas.drawCircle(
      centre,
      5,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      centre,
      5,
      Paint()
        ..color = Colors.cyanAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawLine(
      centre - const Offset(8, 0),
      centre + const Offset(8, 0),
      Paint()..color = Colors.cyanAccent,
    );
    canvas.drawLine(
      centre - const Offset(0, 8),
      centre + const Offset(0, 8),
      Paint()..color = Colors.cyanAccent,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.result != result ||
      oldDelegate.selectedDetection != selectedDetection ||
      oldDelegate.showAll != showAll ||
      oldDelegate.point != point;
}
