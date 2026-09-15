import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

import '../image_processing/crop_service.dart';
import '../ml/conductor_detector.dart';
import '../ml/conductor_detection.dart';
import '../ml/detection_selector.dart';
import '../ml/detection_store.dart';
import '../ml/model_config.dart';
import '../settings/app_settings.dart';
import 'conductor_overlay.dart';
import 'inspection_screen.dart';

class CropPreviewScreen extends StatefulWidget {
  const CropPreviewScreen({
    super.key,
    required this.path,
    required this.selection,
    this.jobName,
    this.initialNotes = '',
  });
  final String path;
  final CropSelection selection;
  final String? jobName;
  final String initialNotes;
  @override
  State<CropPreviewScreen> createState() => _CropPreviewScreenState();
}

class _CropPreviewScreenState extends State<CropPreviewScreen> {
  final _detector = ConductorDetector(
    config: conductorModelConfig.copyWith(
      minimumConfidence: AppSettings.instance.minimumConfidence,
      maskThreshold: AppSettings.instance.maskThreshold,
      maximumPointDistance: AppSettings.instance.maximumPointDistance,
    ),
  );
  final _notesController = TextEditingController();
  ConductorDetectionResult? _result;
  ConductorDetection? _selectedDetection;
  bool _busy = false, _debug = false, _accepted = false;
  bool _calibrating = false;
  final _calibrationPoints = <Offset>[];
  String? _error;
  double? _millimetresPerPixel;

  @override
  void initState() {
    super.initState();
    _notesController.text = widget.initialNotes;
    AppSettings.instance.addListener(_settingsChanged);
    // Load the native graph while the crop is being reviewed so the first
    // analysis does not pay the model startup cost.
    unawaited(
      _detector.initialise().catchError((Object error) {
        debugPrint('Detector warm-up: $error');
      }),
    );
    unawaited(_restoreSavedAcceptance());
  }

  Future<void> _restoreSavedAcceptance() async {
    final acceptedFile = File('${widget.path}.accepted.json');
    if (!await acceptedFile.exists()) return;
    try {
      final decoded = jsonDecode(await acceptedFile.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final maskPath =
          decoded['maskPath'] as String? ?? '${widget.path}.accepted-mask.png';
      final maskImage = img.decodeImage(await File(maskPath).readAsBytes());
      if (maskImage == null ||
          maskImage.width != 512 ||
          maskImage.height != 512) {
        return;
      }
      final binaryMask = Uint8List(512 * 512);
      var maskArea = 0;
      for (var y = 0; y < 512; y++) {
        for (var x = 0; x < 512; x++) {
          final value = maskImage.getPixel(x, y).r > 0 ? 1 : 0;
          binaryMask[y * 512 + x] = value;
          maskArea += value;
        }
      }
      final boxValues = decoded['boxXYXY'];
      if (boxValues is! List ||
          boxValues.length != 4 ||
          boxValues.any((value) => value is! num)) {
        return;
      }
      final detection = ConductorDetection(
        index: _intValue(decoded['detectionIndex']) ?? 0,
        confidence: _doubleValue(decoded['confidence']) ?? 0,
        boundingBox: Rect.fromLTRB(
          (boxValues[0] as num).toDouble(),
          (boxValues[1] as num).toDouble(),
          (boxValues[2] as num).toDouble(),
          (boxValues[3] as num).toDouble(),
        ),
        binaryMask: binaryMask,
        maskArea: _intValue(decoded['maskArea']) ?? maskArea,
        distanceFromSelectedPoint: 0,
        containsSelectedPoint: true,
        classId: _intValue(decoded['classId']),
      );
      final savedPoint = Offset(
        _doubleValue(decoded['selectedCropX']) ?? _point.dx,
        _doubleValue(decoded['selectedCropY']) ?? _point.dy,
      );
      final inference = Duration(
        milliseconds: _intValue(decoded['inferenceMilliseconds']) ?? 0,
      );
      if (!mounted) return;
      setState(() {
        _result = ConductorDetectionResult(
          detections: [detection],
          selectedDetection: detection,
          inferenceTime: inference,
          totalTime: inference,
          selectedPoint: savedPoint,
        );
        _accepted = true;
        _millimetresPerPixel = _doubleValue(decoded['millimetresPerPixel']);
      });
    } catch (error) {
      debugPrint('Saved acceptance could not be restored: $error');
    }
  }

  static int? _intValue(Object? value) => value is num ? value.toInt() : null;

  static double? _doubleValue(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  void _settingsChanged() {
    if (mounted) setState(() {});
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
      _selectedDetection = null;
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
    final selected = _selectedDetection ?? result?.selectedDetection;
    if (selected == null) return;
    final widthMm = _millimetresPerPixel == null
        ? null
        : selected.segmentationWidth * _millimetresPerPixel!;
    final isInches = AppSettings.instance.unit == MeasurementUnit.inches;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DetectionStore.save(widget.path, result!, {
        ...widget.selection.toJson(),
        if (widget.jobName?.trim().isNotEmpty == true)
          'jobName': widget.jobName!.trim(),
        'notes': _notesController.text.trim(),
        'measurementUnit': AppSettings.instance.unit.name,
        if (_millimetresPerPixel case final ratio?) ...{
          'millimetresPerPixel': ratio,
          'segmentationWidthMm': selected.segmentationWidth * ratio,
          if (widthMm case final mm?)
            'displayedWidth': isInches ? mm / 25.4 : mm,
        },
      }, selectedDetection: selected);
      if (mounted) setState(() => _accepted = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save acceptance: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _beginCalibration() {
    setState(() {
      _calibrating = true;
      _calibrationPoints.clear();
    });
  }

  Future<void> _calibrationTap(Offset local, Size displayedSize) async {
    if (!_calibrating ||
        displayedSize.width <= 0 ||
        displayedSize.height <= 0) {
      return;
    }
    final point = Offset(
      (local.dx / displayedSize.width * widget.selection.cropWidth)
          .clamp(0, widget.selection.cropWidth - 1)
          .toDouble(),
      (local.dy / displayedSize.height * widget.selection.cropHeight)
          .clamp(0, widget.selection.cropHeight - 1)
          .toDouble(),
    );
    if (_calibrationPoints.length >= 2) return;
    setState(() => _calibrationPoints.add(point));
    if (_calibrationPoints.length == 2) {
      await _finishCalibration();
    }
  }

  Future<void> _finishCalibration() async {
    final first = _calibrationPoints[0];
    final second = _calibrationPoints[1];
    final pixelDistance = (second - first).distance;
    if (pixelDistance <= 0) return;
    final millimetres = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set calibration distance'),
        content: TextField(
          controller: millimetres,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Known distance (mm)',
            hintText: 'e.g. 25',
          ),
          onSubmitted: (_) {
            final parsed = double.tryParse(millimetres.text.trim());
            if (parsed != null && parsed > 0) {
              Navigator.of(context).pop(parsed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(millimetres.text.trim());
              if (parsed == null || parsed <= 0) return;
              Navigator.of(context).pop(parsed);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    millimetres.dispose();
    if (!mounted) return;
    setState(() {
      _calibrating = false;
      if (value != null) _millimetresPerPixel = value / pixelDistance;
    });
  }

  Future<void> _share() async {
    final result = _result;
    final selected = _selectedDetection ?? result?.selectedDetection;
    final widthMm = selected == null || _millimetresPerPixel == null
        ? null
        : selected.segmentationWidth * _millimetresPerPixel!;
    final inInches = AppSettings.instance.unit == MeasurementUnit.inches;
    final displayedWidth = widthMm == null
        ? null
        : inInches
        ? widthMm / 25.4
        : widthMm;
    final files = <XFile>[XFile(widget.path)];
    final maskPath = '${widget.path}.accepted-mask.png';
    if (await File(maskPath).exists()) files.add(XFile(maskPath));
    final lines = <String>[
      if (widget.jobName?.trim().isNotEmpty == true)
        'Job: ${widget.jobName!.trim()}',
      'Crop: ${widget.selection.cropWidth} x ${widget.selection.cropHeight} px',
      if (selected != null) ...[
        'Segmented width: ${selected.segmentationWidth} px',
        'Confidence: ${(selected.confidence * 100).toStringAsFixed(1)}%',
        if (displayedWidth case final display?)
          'Estimated width: ${display.toStringAsFixed(inInches ? 2 : 1)} ${inInches ? 'in' : 'mm'}',
      ],
      if (_notesController.text.trim().isNotEmpty)
        'Notes: ${_notesController.text.trim()}',
    ];
    final report = <String, Object?>{
      'jobName': widget.jobName?.trim(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'selection': widget.selection.toJson(),
      'notes': _notesController.text.trim(),
      'measurementUnit': AppSettings.instance.unit.name,
      if (selected != null) ...{
        'confidence': selected.confidence,
        'segmentationWidthPx': selected.segmentationWidth,
        'maskAreaPx': selected.maskArea,
        'boundingBoxXYXY': [
          selected.boundingBox.left,
          selected.boundingBox.top,
          selected.boundingBox.right,
          selected.boundingBox.bottom,
        ],
        ...?widthMm == null ? null : {'widthMm': widthMm},
        ...?displayedWidth == null ? null : {'displayedWidth': displayedWidth},
      },
    };
    final reportBase = '${widget.path}.report';
    final jsonPath = '$reportBase.json';
    final csvPath = '$reportBase.csv';
    final textPath = '$reportBase.txt';
    await File(jsonPath).writeAsString(jsonEncode(report), flush: true);
    await File(csvPath).writeAsString(
      '''jobName,createdAt,segmentationWidthPx,widthMm,confidence,maskAreaPx
"${_csv(widget.jobName ?? '')}","${report['createdAt']}",${selected?.segmentationWidth ?? ''},${widthMm ?? ''},${selected?.confidence ?? ''},${selected?.maskArea ?? ''}
''',
      flush: true,
    );
    await File(textPath).writeAsString(
      '${lines.join('\n')}\n\nJSON and CSV data attached.',
      flush: true,
    );
    files.addAll([XFile(textPath), XFile(jsonPath), XFile(csvPath)]);
    final legacyLines = <String>[
      if (widget.jobName?.trim().isNotEmpty == true)
        'Job: ${widget.jobName!.trim()}',
      'Crop: ${widget.selection.cropWidth} × ${widget.selection.cropHeight} px',
      if (selected != null) ...[
        'Segmented width: ${selected.segmentationWidth} px',
        'Confidence: ${(selected.confidence * 100).toStringAsFixed(1)}%',
        if (_millimetresPerPixel case final ratio?)
          'Estimated width: ${(selected.segmentationWidth * ratio).toStringAsFixed(1)} mm',
      ],
      if (_notesController.text.trim().isNotEmpty)
        'Notes: ${_notesController.text.trim()}',
    ];
    // Keep the share summary built above as the source of the text report.
    legacyLines;
    try {
      await SharePlus.instance.share(
        ShareParams(
          title: widget.jobName?.trim().isNotEmpty == true
              ? widget.jobName!.trim()
              : 'Powerline Measure inspection',
          text: lines.join('\n'),
          files: files,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share report: $e')));
      }
    }
  }

  static String _csv(String value) => value.replaceAll('"', '""');

  @override
  void dispose() {
    AppSettings.instance.removeListener(_settingsChanged);
    _notesController.dispose();
    unawaited(
      _detector.dispose().catchError((Object e) {
        debugPrint('Detector cleanup: $e');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDetection ?? _result?.selectedDetection;
    final widthMm = selected == null || _millimetresPerPixel == null
        ? null
        : selected.segmentationWidth * _millimetresPerPixel!;
    final inInches = AppSettings.instance.unit == MeasurementUnit.inches;
    final displayedWidth = widthMm == null
        ? null
        : inInches
        ? widthMm / 25.4
        : widthMm;
    final unitLabel = inInches ? 'in' : 'mm';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.jobName?.isNotEmpty == true
              ? '${widget.jobName} - Inspection'
              : 'Conductor inspection',
        ),
      ),
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
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: _calibrating
                                    ? (details) => _calibrationTap(
                                        details.localPosition,
                                        rect.size,
                                      )
                                    : null,
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
                                      selectedDetection: _selectedDetection,
                                      point: _point,
                                      showAll: _debug,
                                      width: widget.selection.cropWidth,
                                      height: widget.selection.cropHeight,
                                    ),
                                    for (
                                      var i = 0;
                                      i < _calibrationPoints.length;
                                      i++
                                    )
                                      Positioned(
                                        left:
                                            _calibrationPoints[i].dx /
                                                widget.selection.cropWidth *
                                                rect.width -
                                            12,
                                        top:
                                            _calibrationPoints[i].dy /
                                                widget.selection.cropHeight *
                                                rect.height -
                                            12,
                                        child: IgnorePointer(
                                          child: Container(
                                            width: 24,
                                            height: 24,
                                            decoration: BoxDecoration(
                                              color: Colors.amber.withValues(
                                                alpha: 0.25,
                                              ),
                                              border: Border.all(
                                                color: Colors.amber,
                                                width: 2,
                                              ),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Center(
                                              child: Text(
                                                '${i + 1}',
                                                style: const TextStyle(
                                                  color: Colors.amber,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
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
                    TextField(
                      controller: _notesController,
                      enabled: !_busy,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Inspection notes (optional)',
                        hintText: 'Pole, span, conductor, or site details',
                      ),
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
                          '${displayedWidth == null ? '' : ' (${displayedWidth.toStringAsFixed(inInches ? 2 : 1)} $unitLabel)'}',
                        ),
                      ] else
                        const Text(
                          'No conductor detected near the selected point.\nTry tapping closer to the conductor or capturing a sharper image.',
                          textAlign: TextAlign.center,
                        ),
                      if (result.detections.where((d) => d.isValid).length > 1)
                        DropdownButton<int>(
                          value: selected?.index,
                          hint: const Text('Choose detected conductor'),
                          items: [
                            for (final detection in result.detections.where(
                              (d) => d.isValid,
                            ))
                              DropdownMenuItem(
                                value: detection.index,
                                child: Text(
                                  'Conductor #${detection.index} - '
                                  '${(detection.confidence * 100).toStringAsFixed(1)}%',
                                ),
                              ),
                          ],
                          onChanged: (index) {
                            if (index == null) return;
                            setState(
                              () => _selectedDetection = result.detections
                                  .firstWhere((d) => d.index == index),
                            );
                          },
                        ),
                    ],
                    if (_calibrating)
                      Text(
                        _calibrationPoints.isEmpty
                            ? 'Calibration: tap the first reference point.'
                            : 'Calibration: tap the second reference point.',
                        textAlign: TextAlign.center,
                      ),
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
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : (_calibrating
                                    ? () => setState(() {
                                        _calibrating = false;
                                        _calibrationPoints.clear();
                                      })
                                    : _beginCalibration),
                          icon: const Icon(Icons.straighten),
                          label: Text(
                            _calibrating
                                ? 'Cancel calibration'
                                : _millimetresPerPixel == null
                                ? 'Calibrate (2 points)'
                                : 'Recalibrate (2 points)',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _share,
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Share'),
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
