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
      } on PlatformException catch (e) {
        // Metadata is not supported by the plugin on some Apple backends.
        if (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS) {
          rethrow;
        }
        _log('Metadata unavailable on this backend: $e');
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
        final shape = (info['shape'] as List).cast<num>();
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
        if (info['type'] != config.dataType.name) {
          throw StateError(
            'Model input type ${info['type']} differs from ${config.dataType.name}.',
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
      for (final entry in outputs.entries) {
        _log(
          'Output ${entry.key}: ${entry.value.shape} ${entry.value.dataType.name}',
        );
        // The Swift backend can return null data for a valid zero-length
        // tensor (for example, [0, 4] boxes on an image with no detections).
        // Avoid the plugin's null-to-List cast and represent it as [] instead.
        final values = entry.value.shape.any((dimension) => dimension == 0)
            ? <num>[]
            : (await entry.value.asFlattenedList()).cast<num>();
        tensors[entry.key] = ModelTensor(
          entry.value.shape,
          values,
          entry.value.dataType.name,
        );
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
}
