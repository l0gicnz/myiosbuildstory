import 'dart:io';

import 'package:flutter/material.dart';

import '../image_processing/crop_service.dart';
import 'interactive_image.dart';
import 'crop_preview_screen.dart';
import '../settings/app_settings.dart';

class InspectionScreen extends StatefulWidget {
  const InspectionScreen({
    super.key,
    required this.source,
    this.jobName,
    this.location,
    this.cameraMetadata,
    this.rangefinderDistanceMetres,
  });
  final InspectionImage source;
  final String? jobName;
  final Map<String, Object?>? location;
  final Map<String, Object?>? cameraMetadata;
  final double? rangefinderDistanceMetres;
  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  CropSelection? _selection;
  bool _busy = false;
  bool _calibrating = false;
  final _calibrationPoints = <Offset>[];
  int _activeCalibrationPoint = 0;
  Future<void> _openCrop() async {
    final selection = _selection;
    if (selection == null || _busy) return;
    setState(() => _busy = true);
    try {
      final path = await CropService.extract(
        widget.source,
        selection,
        jobName: widget.jobName,
        location: widget.location,
        cameraMetadata: widget.cameraMetadata ?? widget.source.cameraMetadata,
        rangefinderDistanceMetres: widget.rangefinderDistanceMetres,
      );
      if (!mounted) return;
      // The stable record path is deliberately overwritten for every crop.
      // Evict its old decoded image or Image.file may keep showing the
      // previous crop from Flutter's global image cache.
      await FileImage(File(path)).evict();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CropPreviewScreen(
            path: path,
            selection: selection,
            jobName: widget.jobName,
            location: widget.location,
            cameraMetadata: widget.cameraMetadata ?? widget.source.cameraMetadata,
            rangefinderDistanceMetres: widget.rangefinderDistanceMetres,
            initialMillimetresPerPixel: _millimetresPerPixel,
          ),
        ),
      );
      if (!AppSettings.instance.retainOriginalPhotos) {
        for (final path in [widget.source.originalPath, widget.source.path]) {
          try {
            await File(path).delete();
          } on FileSystemException {
            // The crop remains available even if an optional source file is
            // already gone.
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create crop: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double? get _millimetresPerPixel {
    if (_calibrationPoints.length != 2) return null;
    final pixels = (_calibrationPoints[1] - _calibrationPoints[0]).distance;
    // CropService copies a square of source pixels without resizing. Therefore
    // one segmentation-mask pixel corresponds to one upright source pixel.
    return pixels > 0 ? _calibrationDistanceMm / pixels : null;
  }

  double _calibrationDistanceMm = 0;

  Future<void> _finishCalibration() async {
    if (_calibrationPoints.length != 2) return;
    final controller = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set calibration distance'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Known distance (mm)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed != null && parsed > 0) Navigator.pop(context, parsed);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    setState(() {
      _calibrationDistanceMm = value;
      _calibrating = false;
    });
  }

  void _nudgeCalibrationPoint(Offset delta) {
    if (_calibrationPoints.isEmpty) return;
    final point = _calibrationPoints[_activeCalibrationPoint];
    setState(() {
      _calibrationPoints[_activeCalibrationPoint] = Offset(
        (point.dx + delta.dx).clamp(0, widget.source.width - 1).toDouble(),
        (point.dy + delta.dy).clamp(0, widget.source.height - 1).toDouble(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final calibrationScale = _millimetresPerPixel;
    return Scaffold(
    appBar: AppBar(
      title: Text(
        widget.jobName?.isNotEmpty == true ? widget.jobName! : 'Inspect photo',
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Retake'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Pinch to zoom and drag to frame the conductor, then tap the area to inspect.',
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: InteractiveImage(
              source: widget.source,
            selection: _selection,
              calibrating: _calibrating,
              calibrationPoints: _calibrationPoints,
              onCalibrationTap: (point) {
                if (_calibrationPoints.length >= 2) return;
                setState(() {
                  _calibrationPoints.add(point);
                  _activeCalibrationPoint = _calibrationPoints.length - 1;
                });
              },
              onSelect: (point) {
                if (_busy) return;
                setState(
                  () => _selection = CropService.calculate(
                    width: widget.source.width,
                    height: widget.source.height,
                    x: point.dx,
                    y: point.dy,
                  ),
                );
              },
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.4,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
              children: [
                if (_selection case final s?)
                  Text(selectionDescription(s), textAlign: TextAlign.center),
                if (widget.source.width < 512 || widget.source.height < 512)
                  const Text(
                    'Source is smaller than 512 pixels; crop uses available pixels.',
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _selection == null || _busy ? null : _openCrop,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.crop),
                  label: Text(_busy ? 'Extracting...' : 'Open crop'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : (_calibrating
                          ? (_calibrationPoints.length == 2
                              ? _finishCalibration
                              : () => setState(() {
                                    _calibrating = false;
                                    _calibrationPoints.clear();
                                  }))
                          : () => setState(() {
                                _calibrating = true;
                                _calibrationPoints.clear();
                              })),
                  icon: const Icon(Icons.straighten),
                  label: Text(_calibrating
                      ? (_calibrationPoints.length == 2
                          ? 'Apply calibration'
                          : 'Cancel calibration')
                      : 'Calibrate (2 points)'),
                ),
                if (_calibrating)
                  Column(
                    children: [
                      Text(
                        _calibrationPoints.isEmpty
                            ? 'Tap the first reference point on the full-resolution image.'
                            : _calibrationPoints.length == 1
                                ? 'Tap the second reference point.'
                                : 'Select a point and fine-tune it one pixel at a time.',
                        textAlign: TextAlign.center,
                      ),
                      if (_calibrationPoints.isNotEmpty)
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ChoiceChip(
                              label: const Text('Point 1'),
                              selected: _activeCalibrationPoint == 0,
                              onSelected: (_) => setState(() => _activeCalibrationPoint = 0),
                            ),
                            if (_calibrationPoints.length > 1)
                              ChoiceChip(
                                label: const Text('Point 2'),
                                selected: _activeCalibrationPoint == 1,
                                onSelected: (_) => setState(() => _activeCalibrationPoint = 1),
                              ),
                            IconButton(onPressed: () => _nudgeCalibrationPoint(const Offset(-1, 0)), icon: const Icon(Icons.chevron_left)),
                            IconButton(onPressed: () => _nudgeCalibrationPoint(const Offset(0, -1)), icon: const Icon(Icons.expand_less)),
                            IconButton(onPressed: () => _nudgeCalibrationPoint(const Offset(0, 1)), icon: const Icon(Icons.expand_more)),
                            IconButton(onPressed: () => _nudgeCalibrationPoint(const Offset(1, 0)), icon: const Icon(Icons.chevron_right)),
                            if (_calibrationPoints.length == 2)
                              Text('${(_calibrationPoints[1] - _calibrationPoints[0]).distance.toStringAsFixed(1)} px'),
                          ],
                        ),
                    ],
                  ),
                if (!_calibrating && calibrationScale != null)
                  Text(
                    'Calibration: ${_calibrationDistanceMm.toStringAsFixed(2)} mm over '
                    '${(_calibrationDistanceMm / calibrationScale).toStringAsFixed(1)} px '
                    '= ${calibrationScale.toStringAsFixed(4)} mm/px',
                    textAlign: TextAlign.center,
                  ),
              ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
  }
}

String selectionDescription(CropSelection s) =>
    'Selected pixel: (${s.selectedX}, ${s.selectedY})\n'
    'Crop origin: (${s.cropX}, ${s.cropY}) - ${s.cropWidth} x ${s.cropHeight} px';
