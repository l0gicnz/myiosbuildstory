import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'conductor_detection.dart';
import 'detection_selector.dart';
import 'mask_postprocessor.dart';
import 'model_config.dart';
import 'model_preprocessor.dart';

/// Owns one native session. All operations are serialized, including disposal.
/// No widgets, navigation, or remote inference are used here.
class ConductorDetector {
  ConductorDetector({
    this.config = conductorModelConfig,
    void Function(String)? logger,
  }) : _logger = logger ?? _developmentLog;
  final ModelConfig config;
  final void Function(String) _logger;
  final List<String> diagnostics = [];
  OrtSession? _session;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  static void _developmentLog(String message) {
    if (kDebugMode) debugPrint(message);
  }

  void _log(String message) {
    diagnostics.add(message);
    if (diagnostics.length > 100) diagnostics.removeAt(0);
    _logger(message);
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    if (_disposed) return Future.error(StateError('Detector is disposed.'));
    final task = _tail.then((_) => work());
    _tail = task.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return task;
  }

  Future<void> initialise() => _serial(_initialise);

  Future<void> _initialise() async {
    if (_session != null) return;
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    if (!manifest.listAssets().contains(config.assetPath)) {
      throw StateError(
        'ONNX model missing: ${config.assetPath}. Add the real model to assets/models/, '
        'register it in pubspec.yaml, and rebuild the app.',
      );
    }
    final session = await OnnxRuntime().createSessionFromAsset(
      config.assetPath,
    );
    try {
      _log(
        'ONNX inputs: ${session.inputNames}; outputs: ${session.outputNames}',
      );
      List<Map<String, dynamic>> inputs = [];
      try {
        inputs = await session.getInputInfo();
        _log('ONNX input tensors: $inputs');
        _log('ONNX output tensors: ${await session.getOutputInfo()}');
      } catch (e) {
        // Metadata is not supported reliably by some Apple backends. The
        // plugin can surface a missing field as a Dart cast error instead of
        // a PlatformException, so do not let optional metadata prevent the
        // already-configured model from running.
        if (!_isApple) rethrow;
        _log('Input/output metadata unavailable on this backend: $e');
      }
      config.validate();
      if (session.inputNames.length != 1 ||
          !session.inputNames.contains(config.inputName)) {
        throw StateError(
          'Configured input ${config.inputName} does not match ${session.inputNames}.',
        );
      }
      for (final name in [
        config.boxesName,
        config.scoresName,
        config.masksName,
        config.labelsName,
      ]) {
        if (name != null && !session.outputNames.contains(name)) {
          throw StateError(
            'Configured output $name does not match ${session.outputNames}.',
          );
        }
      }
      for (final info in inputs) {
        if (info['name'] != config.inputName) continue;
        final rawShape = info['shape'];
        if (rawShape is! List) {
          _log('Input metadata has no readable shape; skipping shape check.');
          continue;
        }
        final shape = rawShape.whereType<num>().toList(growable: false);
        if (shape.length != rawShape.length) {
          _log('Input metadata shape is not numeric; skipping shape check.');
          continue;
        }
        final expected = config.inputShape;
        if (shape.length != expected.length ||
            List.generate(
              shape.length,
              (i) => shape[i] > 0 && shape[i] != expected[i],
            ).any((v) => v)) {
          throw StateError(
            'Model input $shape does not match configured $expected.',
          );
        }
        final type = info['type'];
        if (type is String && type != config.dataType.name) {
          throw StateError(
            'Model input type $type differs from ${config.dataType.name}.',
          );
        }
      }
      _session = session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<ConductorDetectionResult> analyse(
    Uint8List cropBytes,
    Offset selectedPoint,
  ) => _serial(() async {
    DetectionSelector.validatePoint(selectedPoint, config.width, config.height);
    await _initialise();
    final total = Stopwatch()..start();
    final prepared = await compute(_prepare, (cropBytes, config));
    OrtValue? input;
    Map<String, OrtValue> outputs = {};
    try {
      input = await OrtValue.fromList(prepared.values, prepared.shape);
      _log('Input ${config.inputName}: ${input.shape} ${input.dataType.name}');
      final timer = Stopwatch()..start();
      outputs = await _session!.run({config.inputName!: input});
      timer.stop();
      final tensors = <String, ModelTensor>{};
      final isApple = _isApple;
      final requiredOutputs = <String>{
        config.boxesName!,
        config.scoresName!,
        config.masksName!,
        if (config.labelsName != null && !isApple) config.labelsName!,
      };
      for (final entry in outputs.entries) {
        if (!requiredOutputs.contains(entry.key)) {
          _log('Ignoring unconfigured output ${entry.key}.');
          continue;
        }
        _log(
          'Output ${entry.key}: ${entry.value.shape} ${entry.value.dataType.name}',
        );
        // The Swift backend can return null data for a valid zero-length
        // tensor (for example, [0, 4] boxes on an image with no detections).
        // Avoid the plugin's null-to-List cast and represent it as [] instead.
        final values = entry.value.shape.any((dimension) => dimension == 0)
            ? <num>[]
            : await _readOutputValues(entry.key, entry.value);
        tensors[entry.key] = ModelTensor(
          entry.value.shape,
          values,
          entry.value.dataType.name,
        );
      }
      if (isApple && config.labelsName != null) {
        final boxes = tensors[config.boxesName!];
        if (boxes != null && boxes.shape.length == 2) {
          // This export has one foreground class (1). The iOS Swift bridge
          // cannot reliably read this model's int64 labels output, so retain
          // the known class semantics without extracting that tensor.
          tensors[config.labelsName!] = ModelTensor(
            [boxes.shape[0]],
            List<num>.filled(boxes.shape[0], 1),
            'int64',
          );
        }
      }
      final detections = await compute(_decode, (
        tensors,
        config,
        selectedPoint,
      ));
      final selected = DetectionSelector.select(
        detections,
        config.maximumPointDistance,
      );
      for (final d in detections) {
        _log(
          'Detection ${d.index}: class=${d.classId} score=${d.confidence} area=${d.maskArea} '
          'distance=${d.distanceFromSelectedPoint} selected=${identical(d, selected)} reasons=${d.rejectionReasons}',
        );
      }
      total.stop();
      _log(
        'Inference ${timer.elapsedMilliseconds} ms; total ${total.elapsedMilliseconds} ms; ${detections.length} outputs',
      );
      return ConductorDetectionResult(
        detections: detections,
        selectedDetection: selected,
        inferenceTime: timer.elapsed,
        totalTime: total.elapsed,
        selectedPoint: selectedPoint,
      );
    } finally {
      await Future.wait([
        for (final value in outputs.values) value.dispose(),
        if (input != null) input.dispose(),
      ]);
    }
  });

  static PreparedInput _prepare((Uint8List, ModelConfig) request) =>
      ModelPreprocessor.prepare(request.$1, request.$2);

  static Future<List<num>> _readOutputValues(
    String name,
    OrtValue value,
  ) async {
    try {
      dynamic raw = await value.asFlattenedList();
      if (raw == null) {
        throw StateError('native backend returned null tensor data');
      }
      if (raw is! List) {
        throw StateError(
          'native backend returned ${raw.runtimeType}, not a list',
        );
      }
      final values = raw.whereType<num>().toList(growable: false);
      if (values.length != raw.length) {
        throw StateError('tensor contains non-numeric values');
      }
      return values;
    } catch (error) {
      throw FormatException(
        'Could not read ONNX output "$name" with shape ${value.shape} '
        'and type ${value.dataType.name}: $error',
      );
    }
  }

  static List<ConductorDetection> _decode(
    (Map<String, ModelTensor>, ModelConfig, Offset) request,
  ) => MaskPostprocessor.decode(request.$1, request.$2, request.$3);

  Future<void> dispose() {
    if (_disposed) return _tail;
    _disposed = true;
    _tail = _tail.then((_) async {
      final session = _session;
      _session = null;
      await session?.close();
    });
    return _tail;
  }

  static bool get _isApple =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
