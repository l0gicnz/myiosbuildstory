import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../image_processing/crop_service.dart';
import '../ml/conductor_detector.dart';
import '../ml/conductor_detection.dart';
import '../ml/detection_selector.dart';
import '../ml/detection_store.dart';
import 'conductor_overlay.dart';
import 'inspection_screen.dart';

class CropPreviewScreen extends StatefulWidget {
  const CropPreviewScreen({
    super.key,
    required this.path,
    required this.selection,
  });
  final String path;
  final CropSelection selection;
  @override
  State<CropPreviewScreen> createState() => _CropPreviewScreenState();
}

class _CropPreviewScreenState extends State<CropPreviewScreen> {
  final _detector = ConductorDetector();
  ConductorDetectionResult? _result;
  bool _busy = false, _debug = false, _accepted = false;
  String? _error;
  double? _millimetresPerPixel;

  @override
  void initState() {
    super.initState();
    // Load the native graph while the crop is being reviewed so the first
    // analysis does not pay the model startup cost.
    unawaited(
      _detector.initialise().catchError((Object error) {
        debugPrint('Detector warm-up: $error');
      }),
    );
  }

  Offset get _point => DetectionSelector.cropRelativePoint(
    selectedX: widget.selection.selectedX,
    selectedY: widget.selection.selectedY,
    cropX: widget.selection.cropX,
    cropY: widget.selection.cropY,
  );

  Future<void> _analyse() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _accepted = false;
    });
    try {
      final result = await _detector.analyse(
        await File(widget.path).readAsBytes(),
        _point,
      );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = 'Analysis failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final result = _result;
    final selected = result?.selectedDetection;
    if (selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DetectionStore.save(widget.path, result!, {
        ...widget.selection.toJson(),
        if (_millimetresPerPixel case final ratio?) ...{
          'millimetresPerPixel': ratio,
          'segmentationWidthMm': selected.segmentationWidth * ratio,
        },
      });
      if (mounted) setState(() => _accepted = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save acceptance: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _calibrate(ConductorDetection detection) async {
    final millimetres = TextEditingController();
    final pixels = TextEditingController(
      text: detection.segmentationWidth.toString(),
    );
    final values = await showDialog<(double, double)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibrate image scale'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Measure a known reference in this image, then enter its real length and pixel length.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: millimetres,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Reference length (mm)',
              ),
            ),
            TextField(
              controller: pixels,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Reference length (pixels)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final mm = double.tryParse(millimetres.text.trim());
              final px = double.tryParse(pixels.text.trim());
              if (mm == null || px == null || mm <= 0 || px <= 0) return;
              Navigator.of(context).pop((mm, px));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    millimetres.dispose();
    pixels.dispose();
    if (!mounted || values == null) return;
    setState(() => _millimetresPerPixel = values.$1 / values.$2);
  }

  @override
  void dispose() {
    unawaited(
      _detector.dispose().catchError((Object e) {
        debugPrint('Detector cleanup: $e');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _result?.selectedDetection;
    final widthMm = selected == null || _millimetresPerPixel == null
        ? null
        : selected.segmentationWidth * _millimetresPerPixel!;
    return Scaffold(
      appBar: AppBar(title: const Text('Conductor inspection')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 16,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final fitted = applyBoxFit(
                      BoxFit.contain,
                      Size(
                        widget.selection.cropWidth.toDouble(),
                        widget.selection.cropHeight.toDouble(),
                      ),
                      constraints.biggest,
                    );
                    final rect = Alignment.center.inscribe(
                      fitted.destination,
                      Offset.zero & constraints.biggest,
                    );
                    return Stack(
                      children: [
                        Positioned.fromRect(
                          rect: rect,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(
                                File(widget.path),
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.none,
                              ),
                              ConductorOverlay(
                                result: _result,
                                point: _point,
                                showAll: _debug,
                                width: widget.selection.cropWidth,
                                height: widget.selection.cropHeight,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Text(
                      selectionDescription(widget.selection),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      'Tap in crop: (${_point.dx.toInt()}, ${_point.dy.toInt()})',
                    ),
                    if (_busy) const Text('Processing on device...'),
                    if (_error != null)
                      SelectableText(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (_result case final result?) ...[
                      Text(
                        'Inference: ${result.inferenceTime.inMilliseconds} ms | Total: ${result.totalTime.inMilliseconds} ms',
                      ),
                      if (selected != null) ...[
                        Text(
                          'Confidence: ${(selected.confidence * 100).toStringAsFixed(1)}% | Mask: ${selected.maskArea} pixels',
                        ),
                        Text(
                          'Segmented width: ${selected.segmentationWidth} px'
                          '${widthMm == null ? '' : ' (${widthMm.toStringAsFixed(1)} mm)'}',
                        ),
                      ] else
                        const Text(
                          'No conductor detected near the selected point.\nTry tapping closer to the conductor or capturing a sharper image.',
                          textAlign: TextAlign.center,
                        ),
                    ],
                    if (_accepted)
                      const Text('Detection accepted and saved for this crop.'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: _busy ? null : _analyse,
                          child: Text(
                            _result != null || _error != null
                                ? 'Analyse Again'
                                : 'Analyse Conductor',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: _busy || selected == null || _accepted
                              ? null
                              : _accept,
                          child: const Text('Accept Detection'),
                        ),
                        if (selected != null)
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _calibrate(selected),
                            icon: const Icon(Icons.straighten),
                            label: Text(
                              _millimetresPerPixel == null
                                  ? 'Set scale'
                                  : 'Adjust scale',
                            ),
                          ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Retap'),
                        ),
                      ],
                    ),
                    if (kDebugMode) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Debug: all detections'),
                        value: _debug,
                        onChanged: (value) => setState(() => _debug = value),
                      ),
                      if (_debug) ...[
                        const Text(
                          'Green: selected | Orange: valid | Red: rejected',
                        ),
                        for (final d
                            in _result?.detections ?? <ConductorDetection>[])
                          Text(
                            '#${d.index} ${identical(d, selected) ? "SELECTED" : "not selected"} '
                            'class=${d.classId} score=${d.confidence.toStringAsFixed(3)} '
                            'area=${d.maskArea} distance=${d.distanceFromSelectedPoint.toStringAsFixed(1)} px '
                            '${d.rejectionReasons.join("; ")}',
                          ),
                        SelectableText(_detector.diagnostics.join('\n')),
                      ],
                    ],
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
