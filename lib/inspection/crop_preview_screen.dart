import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

class CropPreviewScreen extends StatefulWidget {
  const CropPreviewScreen({
    super.key,
    required this.path,
    required this.selection,
    this.jobName,
    this.location,
    this.cameraMetadata,
    this.rangefinderDistanceMetres,
    this.initialNotes = '',
    this.initialMillimetresPerPixel,
  });
  final String path;
  final CropSelection selection;
  final String? jobName;
  final Map<String, Object?>? location;
  final Map<String, Object?>? cameraMetadata;
  final double? rangefinderDistanceMetres;
  final String initialNotes;
  final double? initialMillimetresPerPixel;
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
  final bool _calibrating = false;
  final _calibrationPoints = <Offset>[];
  int _activeCalibrationPoint = 0;
  String? _error;
  double? _millimetresPerPixel;
  String _scaleSource = 'Not calibrated';

  void _calibrationTap(Offset local, Size displayedSize) {}

  void _moveCalibrationPointByDelta(
    int index,
    Offset delta,
    Size displayedSize,
  ) {}

  @override
  void initState() {
    super.initState();
    _notesController.text = widget.initialNotes;
    final cameraScale = _cameraScale();
    if (cameraScale != null) {
      _millimetresPerPixel = cameraScale;
      _scaleSource = 'Camera/FOV estimate';
    }
    if (widget.initialMillimetresPerPixel != null) {
      _millimetresPerPixel = widget.initialMillimetresPerPixel;
      _scaleSource = 'Two-point calibration';
    }
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
        _scaleSource =
            decoded['scaleSource'] as String? ??
            (_millimetresPerPixel == null ? 'Not calibrated' : 'Saved scale');
      });
    } catch (error) {
      debugPrint('Saved acceptance could not be restored: $error');
    }
  }

  static int? _intValue(Object? value) => value is num ? value.toInt() : null;

  static double? _doubleValue(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  static String _locationLabel(Map<String, Object?> location) {
    final latitude = _doubleValue(location['latitude']);
    final longitude = _doubleValue(location['longitude']);
    if (latitude == null || longitude == null) return 'Unavailable';
    final accuracy = _doubleValue(location['accuracyMetres']);
    return '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}'
        '${accuracy == null ? '' : ' (±${accuracy.toStringAsFixed(0)} m)'}';
  }

  double? _cameraScale() {
    final distance = widget.rangefinderDistanceMetres;
    final metadata = widget.cameraMetadata;
    if (distance == null || distance <= 0 || metadata == null) return null;
    final fov =
        _doubleValue(metadata['correctedFovDegrees']) ??
        _doubleValue(metadata['baseFovDegrees']);
    if (fov == null || fov <= 0 || fov >= 180) return null;
    final zoom = _doubleValue(metadata['zoomFactor']) ?? 1;
    if (zoom <= 0) return null;
    final halfFov = fov * math.pi / 360;
    final effectiveHalfFov = math.atan(math.tan(halfFov) / zoom);
    final widthMm = 2 * distance * 1000 * math.tan(effectiveHalfFov);
    return widthMm / widget.selection.sourceWidth;
  }

  String _cameraScaleDescription() {
    final distance = widget.rangefinderDistanceMetres;
    final fov =
        _doubleValue(widget.cameraMetadata?['correctedFovDegrees']) ??
        _doubleValue(widget.cameraMetadata?['baseFovDegrees']);
    if (distance == null || fov == null) return '';
    return '${distance.toStringAsFixed(2)} m rangefinder · '
        '${fov.toStringAsFixed(1)}° FOV';
  }

  String _rangefinderDescription() {
    final distance = widget.rangefinderDistanceMetres;
    if (distance == null || distance <= 0) return '';
    final metadata = widget.cameraMetadata;
    final cameraModel = metadata?['cameraModel'] as String?;
    final fov =
        _doubleValue(metadata?['correctedFovDegrees']) ??
        _doubleValue(metadata?['baseFovDegrees']);
    final camera = switch ((cameraModel, fov)) {
      (final model?, final degrees?) =>
        ' - $model, ${degrees.toStringAsFixed(1)} deg FOV',
      (final model?, null) => ' - $model',
      _ => '',
    };
    return 'Rangefinder distance: ${distance.toStringAsFixed(2)} m$camera';
  }

  String _cameraScaleAvailabilityMessage() {
    final distance = widget.rangefinderDistanceMetres;
    final metadata = widget.cameraMetadata;
    final fov =
        _doubleValue(metadata?['correctedFovDegrees']) ??
        _doubleValue(metadata?['baseFovDegrees']);
    if (metadata != null && fov != null && fov > 0 && fov < 180) return '';
    if (distance != null && distance > 0) {
      return 'Camera model/FOV data unavailable. The rangefinder distance was '
          'saved, but automatic scale could not be calculated. Use two-point '
          'calibration instead.';
    }
    return 'Camera model/FOV data unavailable. Automatic scale is unavailable; '
        'use two-point calibration instead.';
  }

  String _cameraMetadataStatus() {
    final metadata = widget.cameraMetadata;
    final fov =
        _doubleValue(metadata?['correctedFovDegrees']) ??
        _doubleValue(metadata?['baseFovDegrees']);
    if (metadata == null || fov == null || fov <= 0 || fov >= 180) {
      return 'Camera metadata: unavailable';
    }
    final model = metadata['cameraModel'] as String?;
    return 'Camera metadata: ${model ?? 'iPhone'} · '
        '${fov.toStringAsFixed(1)}° FOV';
  }

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
        'scaleSource': _scaleSource,
        if (widget.rangefinderDistanceMetres case final distance?
            when distance > 0)
          'rangefinderDistanceMetres': distance,
        ...?widget.cameraMetadata == null
            ? null
            : {'cameraMetadata': widget.cameraMetadata!},
        ...?widget.location == null ? null : {'location': widget.location!},
        if (_millimetresPerPixel case final ratio?) ...{
          'millimetresPerPixel': ratio,
          'segmentationWidthMm': selected.segmentationWidth * ratio,
          if (widthMm case final mm?)
            'displayedWidth': isInches ? mm / 25.4 : mm,
        },
        if (_calibrationPoints.length == 2) ...{
          'calibrationPixelDistance':
              (_calibrationPoints[1] - _calibrationPoints[0]).distance,
          'calibrationPoints': [
            [_calibrationPoints[0].dx, _calibrationPoints[0].dy],
            [_calibrationPoints[1].dx, _calibrationPoints[1].dy],
          ],
        },
      }, selectedDetection: selected);
      if (mounted) setState(() => _accepted = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save acceptance: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveNotes() async {
    if (!_accepted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final notes = _notesController.text.trim();
      for (final path in [
        '${widget.path}.accepted.json',
        '${widget.path}.json',
      ]) {
        final file = File(path);
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        decoded['notes'] = notes;
        await file.writeAsString(jsonEncode(decoded), flush: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Notes saved.')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save notes: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* Calibration is handled by InspectionScreen on the full-resolution image.
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
    setState(() {
      _calibrationPoints.add(point);
      _activeCalibrationPoint = _calibrationPoints.length - 1;
    });
  }

  void _moveCalibrationPoint(int index, Offset point) {
    if (index < 0 || index >= _calibrationPoints.length) return;
    setState(() {
      _activeCalibrationPoint = index;
      _calibrationPoints[index] = Offset(
        point.dx.clamp(0, widget.selection.cropWidth - 1).toDouble(),
        point.dy.clamp(0, widget.selection.cropHeight - 1).toDouble(),
      );
    });
  }

  void _nudgeCalibrationPoint(Offset delta) {
    if (_calibrationPoints.isEmpty) return;
    _moveCalibrationPoint(
      _activeCalibrationPoint,
      _calibrationPoints[_activeCalibrationPoint] + delta,
    );
  }

  void _moveCalibrationPointByDelta(
    int index,
    Offset delta,
    Size displayedSize,
  ) {
    if (displayedSize.width <= 0 || displayedSize.height <= 0) return;
    _moveCalibrationPoint(
      index,
      _calibrationPoints[index] +
          Offset(
            delta.dx / displayedSize.width * widget.selection.cropWidth,
            delta.dy / displayedSize.height * widget.selection.cropHeight,
          ),
    );
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
    final ratio = value == null ? null : value / pixelDistance;
    setState(() {
      _calibrating = false;
      if (ratio != null) {
        _millimetresPerPixel = ratio;
        _scaleSource = 'Two-point calibration';
      }
    });
    if (ratio != null && _accepted) await _persistCalibration(ratio);
  }

  Future<void> _persistCalibration(double ratio) async {
    try {
      final file = File('${widget.path}.accepted.json');
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final selected = _selectedDetection ?? _result?.selectedDetection;
      final unit = AppSettings.instance.unit;
      final widthMm = selected == null
          ? null
          : selected.segmentationWidth * ratio;
      decoded['millimetresPerPixel'] = ratio;
      if (widthMm != null) {
        decoded['segmentationWidthMm'] = widthMm;
        decoded['displayedWidth'] = unit == MeasurementUnit.inches
            ? widthMm / 25.4
            : widthMm;
      }
      decoded['calibrationPixelDistance'] =
          (_calibrationPoints[1] - _calibrationPoints[0]).distance;
      decoded['calibrationPoints'] = [
        [_calibrationPoints[0].dx, _calibrationPoints[0].dy],
        [_calibrationPoints[1].dx, _calibrationPoints[1].dy],
      ];
      decoded['measurementUnit'] = unit.name;
      decoded['scaleSource'] = 'Two-point calibration';
      await file.writeAsString(jsonEncode(decoded), flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Calibration saved.')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save calibration: $e');
      }
    }
  }
  */

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
      if (widget.location case final location?)
        'Location: ${_locationLabel(location)}',
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
      ...?widget.location == null ? null : {'location': widget.location},
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
                                    ) ...[
                                      Positioned(
                                        left:
                                            _calibrationPoints[i].dx /
                                                widget.selection.cropWidth *
                                                rect.width -
                                            20,
                                        top:
                                            _calibrationPoints[i].dy /
                                                widget.selection.cropHeight *
                                                rect.height -
                                            20,
                                        child: IgnorePointer(
                                          child: SizedBox.square(
                                            dimension: 40,
                                            child: CustomPaint(
                                              painter:
                                                  _CalibrationCrosshairPainter(
                                                    active:
                                                        i ==
                                                        _activeCalibrationPoint,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        left:
                                            (_calibrationPoints[i].dx /
                                                        widget
                                                            .selection
                                                            .cropWidth *
                                                        rect.width +
                                                    14)
                                                .clamp(0, rect.width - 40)
                                                .toDouble(),
                                        top:
                                            (_calibrationPoints[i].dy /
                                                        widget
                                                            .selection
                                                            .cropHeight *
                                                        rect.height -
                                                    32)
                                                .clamp(0, rect.height - 40)
                                                .toDouble(),
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: _calibrating
                                              ? () => setState(
                                                  () =>
                                                      _activeCalibrationPoint =
                                                          i,
                                                )
                                              : null,
                                          onPanStart: _calibrating
                                              ? (_) => setState(
                                                  () =>
                                                      _activeCalibrationPoint =
                                                          i,
                                                )
                                              : null,
                                          onPanUpdate: _calibrating
                                              ? (details) =>
                                                    _moveCalibrationPointByDelta(
                                                      i,
                                                      details.delta,
                                                      rect.size,
                                                    )
                                              : null,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.7,
                                              ),
                                              border: Border.all(
                                                color:
                                                    i == _activeCalibrationPoint
                                                    ? Colors.amber
                                                    : Colors.white70,
                                                width: 1.5,
                                              ),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Center(
                                              child: Icon(
                                                Icons.open_with,
                                                size: 20,
                                                color: Colors.amber,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
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
                    const Text(
                      'Crop preview · tap Calibrate to set a scale from two visible reference points.',
                      textAlign: TextAlign.center,
                    ),
                    if (widget.location case final location?)
                      Text('Location: ${_locationLabel(location)}'),
                    if (_rangefinderDescription().isNotEmpty)
                      Text(
                        _rangefinderDescription(),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (widget.rangefinderDistanceMetres == null)
                      const Text('Rangefinder distance: not entered'),
                    Text(_cameraMetadataStatus()),
                    if (_cameraScaleAvailabilityMessage().isNotEmpty)
                      Text(
                        _cameraScaleAvailabilityMessage(),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
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
                      if (selected != null) ...[
                        Text(
                          'Segmented width: ${selected.segmentationWidth} px'
                          '${displayedWidth == null ? '' : ' (${displayedWidth.toStringAsFixed(inInches ? 2 : 1)} $unitLabel)'}',
                        ),
                        if (_millimetresPerPixel != null)
                          Text(
                            'Scale: ${_millimetresPerPixel!.toStringAsFixed(4)} mm/px · $_scaleSource',
                          ),
                        if (_scaleSource == 'Camera/FOV estimate')
                          Text(_cameraScaleDescription()),
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
                    TextField(
                      controller: _notesController,
                      enabled: !_busy,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Inspection notes (optional)',
                        hintText: 'Pole, span, conductor, or site details',
                      ),
                    ),
                    if (_accepted)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _saveNotes,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save notes'),
                        ),
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

class _CalibrationCrosshairPainter extends CustomPainter {
  const _CalibrationCrosshairPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final color = active ? Colors.amberAccent : Colors.white;
    final shadow = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(centre, 8, shadow);
    canvas.drawCircle(centre, 8, line);
    canvas.drawLine(
      Offset(centre.dx - 17, centre.dy),
      Offset(centre.dx - 5, centre.dy),
      shadow,
    );
    canvas.drawLine(
      Offset(centre.dx + 5, centre.dy),
      Offset(centre.dx + 17, centre.dy),
      shadow,
    );
    canvas.drawLine(
      Offset(centre.dx, centre.dy - 17),
      Offset(centre.dx, centre.dy - 5),
      shadow,
    );
    canvas.drawLine(
      Offset(centre.dx, centre.dy + 5),
      Offset(centre.dx, centre.dy + 17),
      shadow,
    );
    canvas.drawLine(
      Offset(centre.dx - 17, centre.dy),
      Offset(centre.dx - 5, centre.dy),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx + 5, centre.dy),
      Offset(centre.dx + 17, centre.dy),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx, centre.dy - 17),
      Offset(centre.dx, centre.dy - 5),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx, centre.dy + 5),
      Offset(centre.dx, centre.dy + 17),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _CalibrationCrosshairPainter oldDelegate) =>
      oldDelegate.active != active;
}
