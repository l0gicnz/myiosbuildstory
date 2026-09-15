import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'conductor_detection.dart';
import 'detection_selector.dart';
import 'model_config.dart';

class MaskPostprocessor {
  static Rect convertBox(List<num> values, ModelConfig config) {
    if (values.length != 4 || values.any((v) => !v.isFinite)) {
      throw const FormatException(
        'Bounding box must contain four finite values.',
      );
    }
    final v = values.map((n) => n.toDouble()).toList();
    var box = switch (config.boxFormat) {
      BoxFormat.xyxy => Rect.fromLTRB(v[0], v[1], v[2], v[3]),
      BoxFormat.xywh => Rect.fromLTWH(v[0], v[1], v[2], v[3]),
      BoxFormat.yxyx => Rect.fromLTRB(v[1], v[0], v[3], v[2]),
    };
    if (config.normalizedBoxes) {
      box = Rect.fromLTRB(
        box.left * config.width,
        box.top * config.height,
        box.right * config.width,
        box.bottom * config.height,
      );
    }
    // Keep the original box for ROI projection; clipping first distorts masks.
    return box;
  }

  static Uint8List projectMask(
    List<num> probabilities,
    int maskWidth,
    int maskHeight,
    Rect box,
    ModelConfig config,
  ) {
    if (maskWidth <= 0 ||
        maskHeight <= 0 ||
        probabilities.length != maskWidth * maskHeight) {
      throw const FormatException('Invalid mask dimensions.');
    }
    if (probabilities.any(
      (v) => !v.isFinite || (!config.maskLogits && (v < 0 || v > 1)),
    )) {
      throw const FormatException(
        'Mask contains invalid probabilities; check logits configuration.',
      );
    }
    if (config.maskSpace == MaskSpace.fullImage &&
        (maskWidth != config.width || maskHeight != config.height)) {
      throw const FormatException(
        'Full-image mask size must match crop. Configure ROI masks explicitly.',
      );
    }
    final result = Uint8List(config.width * config.height);
    if (box.isEmpty) return result;
    double probability(int x, int y) {
      if (x < 0 || y < 0 || x >= maskWidth || y >= maskHeight) return 0;
      final value = probabilities[y * maskWidth + x].toDouble();
      return config.maskLogits ? 1 / (1 + math.exp(-value)) : value;
    }

    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        double value;
        if (config.maskSpace == MaskSpace.fullImage) {
          value = probability(x, y);
        } else {
          if (!box.contains(Offset(x + 0.5, y + 0.5))) continue;
          // Bilinear sampling at output pixel centres, align_corners=false.
          final mx = (x + 0.5 - box.left) / box.width * maskWidth - 0.5;
          final my = (y + 0.5 - box.top) / box.height * maskHeight - 0.5;
          final x0 = mx.floor(), y0 = my.floor();
          final dx = mx - x0, dy = my - y0;
          value =
              probability(x0, y0) * (1 - dx) * (1 - dy) +
              probability(x0 + 1, y0) * dx * (1 - dy) +
              probability(x0, y0 + 1) * (1 - dx) * dy +
              probability(x0 + 1, y0 + 1) * dx * dy;
        }
        if (value >= config.maskThreshold) result[y * config.width + x] = 1;
      }
    }
    return result;
  }

  static List<ConductorDetection> decode(
    Map<String, ModelTensor> outputs,
    ModelConfig config,
    Offset point,
  ) {
    ModelTensor tensor(String? name) {
      final t = outputs[name];
      if (t == null) throw FormatException('Missing configured output: $name');
      t.validate();
      return t;
    }

    final boxes = tensor(config.boxesName),
        scores = tensor(config.scoresName),
        masks = tensor(config.masksName);
    final labels = config.labelsName == null ? null : tensor(config.labelsName);
    for (final t in [boxes, scores, masks]) {
      if (t.type != 'float32' && t.type != 'float16') {
        throw FormatException(
          'Expected floating-point boxes/scores/masks, got ${t.type}.',
        );
      }
    }
    if (labels != null && labels.type != 'int64' && labels.type != 'int32') {
      throw FormatException('Expected integer labels, got ${labels.type}.');
    }
    if (boxes.shape.length != 2 || boxes.shape[1] != 4) {
      throw FormatException('Expected boxes [N,4], got ${boxes.shape}.');
    }
    final n = boxes.shape[0];
    if (scores.shape.length != 1 ||
        scores.shape[0] != n ||
        (labels != null &&
            (labels.shape.length != 1 || labels.shape[0] != n)) ||
        (masks.shape.length != 3 && masks.shape.length != 4) ||
        masks.shape[0] != n) {
      throw FormatException(
        'Expected scores/labels [N], masks [N,H,W] or [N,C,H,W]. '
        'Got ${scores.shape}, ${labels?.shape}, ${masks.shape}.',
      );
    }
    final mh = masks.shape[masks.shape.length - 2], mw = masks.shape.last;
    final channels = masks.shape.length == 4 ? masks.shape[1] : 1;
    if (channels < 1 || mw < 1 || mh < 1) {
      throw const FormatException('Invalid mask shape.');
    }
    final detections = <ConductorDetection>[];
    for (var i = 0; i < n; i++) {
      final reasons = <String>[];
      final score = scores.values[i].toDouble();
      final labelValue = labels?.values[i];
      if (labelValue != null &&
          (!labelValue.isFinite || labelValue != labelValue.toInt())) {
        throw const FormatException('Class labels must be finite integers.');
      }
      final label = labelValue?.toInt();
      if (!score.isFinite || score < 0 || score > 1) {
        reasons.add('Invalid confidence $score');
      } else if (score < config.minimumConfidence) {
        reasons.add('Confidence below ${config.minimumConfidence}');
      }
      if (config.conductorClassIds.isNotEmpty &&
          !config.conductorClassIds.contains(label)) {
        reasons.add('Class $label is not a conductor');
      }
      final box = convertBox(boxes.values.sublist(i * 4, i * 4 + 4), config);
      if (box.isEmpty ||
          !box.overlaps(
            Rect.fromLTWH(
              0,
              0,
              config.width.toDouble(),
              config.height.toDouble(),
            ),
          )) {
        reasons.add('Empty or off-image bounding box');
      }
      final channel = config.maskChannelFromLabel ? label! : config.maskChannel;
      if (channel < 0 || channel >= channels) {
        throw FormatException(
          'Mask channel $channel outside $channels channels.',
        );
      }
      final start = (i * channels + channel) * mw * mh;
      final mask = projectMask(
        masks.values.sublist(start, start + mw * mh),
        mw,
        mh,
        box,
        config,
      );
      final area = mask.fold<int>(0, (a, b) => a + b);
      if (area < config.minimumMaskArea) {
        reasons.add('Mask area $area below ${config.minimumMaskArea}');
      }
      final proximity = DetectionSelector.proximity(mask, config.width, point);
      if (proximity.distance > config.maximumPointDistance) {
        reasons.add(
          'Distance ${proximity.distance.toStringAsFixed(1)} px exceeds ${config.maximumPointDistance}',
        );
      }
      detections.add(
        ConductorDetection(
          index: i,
          confidence: score,
          boundingBox: box,
          binaryMask: mask,
          maskArea: area,
          classId: label,
          distanceFromSelectedPoint: proximity.distance,
          containsSelectedPoint: proximity.contains,
          rejectionReasons: reasons,
        ),
      );
    }
    return detections;
  }
}
