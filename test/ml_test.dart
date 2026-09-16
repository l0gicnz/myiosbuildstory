import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:powerline_measure/ml/conductor_detection.dart';
import 'package:powerline_measure/ml/detection_selector.dart';
import 'package:powerline_measure/ml/mask_postprocessor.dart';
import 'package:powerline_measure/ml/model_config.dart';
import 'package:powerline_measure/ml/model_preprocessor.dart';

ConductorDetection detection(
  int index,
  double score,
  List<(int, int)> pixels, {
  Offset point = const Offset(256, 256),
  List<String> reasons = const [],
}) {
  final mask = Uint8List(512 * 512);
  for (final (x, y) in pixels) {
    mask[y * 512 + x] = 1;
  }
  final proximity = DetectionSelector.proximity(mask, 512, point);
  return ConductorDetection(
    index: index,
    confidence: score,
    boundingBox: const Rect.fromLTWH(0, 0, 512, 512),
    binaryMask: mask,
    maskArea: pixels.length,
    containsSelectedPoint: proximity.contains,
    distanceFromSelectedPoint: proximity.distance,
    rejectionReasons: reasons,
  );
}

void main() {
  test('conductor thickness is measured perpendicular to its long axis', () {
    final horizontal = <(int, int)>[
      for (var y = 100; y < 108; y++)
        for (var x = 50; x < 450; x++) (x, y),
    ];
    final vertical = <(int, int)>[
      for (var x = 100; x < 108; x++)
        for (var y = 50; y < 450; y++) (x, y),
    ];
    final diagonal = <(int, int)>[];
    for (var y = 40; y < 470; y++) {
      for (var x = 40; x < 470; x++) {
        if ((y - x).abs() <= 4) diagonal.add((x, y));
      }
    }
    expect(detection(0, 0.9, horizontal).segmentationThicknessPixels, closeTo(8, 0.1));
    expect(detection(0, 0.9, vertical).segmentationThicknessPixels, closeTo(8, 0.1));
    expect(detection(0, 0.9, diagonal).segmentationThicknessPixels, closeTo(6.66, 0.1));
  });

  test('containing mask wins over higher confidence nearby mask', () {
    final onTap = detection(0, 0.6, [(256, 256)]);
    final beside = detection(1, 0.99, [(257, 256)]);
    expect(DetectionSelector.select([beside, onTap], 32), same(onTap));
  });
  test('highest confidence among masks containing tap', () {
    final a = detection(0, 0.6, [(256, 256)]);
    final b = detection(1, 0.9, [(256, 256)]);
    expect(DetectionSelector.select([a, b], 32), same(b));
  });
  test(
    'nearest mask fallback ignores misleading bounding box and confidence',
    () {
      final far = detection(0, 0.99, [(276, 256)]);
      final near = detection(1, 0.7, [(259, 260)]);
      expect(near.distanceFromSelectedPoint, 5);
      expect(DetectionSelector.select([far, near], 32), same(near));
    },
  );
  test('far, empty and rejected detections cannot be selected', () {
    expect(
      DetectionSelector.select([
        detection(0, 0.9, [(400, 400)]),
      ], 32),
      isNull,
    );
    expect(DetectionSelector.select([detection(0, 0.9, [])], 32), isNull);
    expect(
      DetectionSelector.select([
        detection(0, 0.9, [(256, 256)], reasons: ['wrong class']),
      ], 32),
      isNull,
    );
    expect(DetectionSelector.select([], 32), isNull);
  });
  test('maximum distance is inclusive', () {
    final d = detection(0, 0.9, [(288, 256)]);
    expect(DetectionSelector.select([d], 32), same(d));
    expect(DetectionSelector.select([d], 31.9), isNull);
  });
  test('actual crop-relative tap handles centre and clamped corners', () {
    expect(
      DetectionSelector.cropRelativePoint(
        selectedX: 2000,
        selectedY: 1500,
        cropX: 1744,
        cropY: 1244,
      ),
      const Offset(256, 256),
    );
    expect(
      DetectionSelector.cropRelativePoint(
        selectedX: 10,
        selectedY: 20,
        cropX: 0,
        cropY: 0,
      ),
      const Offset(10, 20),
    );
    expect(
      DetectionSelector.cropRelativePoint(
        selectedX: 3999,
        selectedY: 2999,
        cropX: 3488,
        cropY: 2488,
      ),
      const Offset(511, 511),
    );
    expect(
      () => DetectionSelector.validatePoint(const Offset(512, 0), 512, 512),
      throwsArgumentError,
    );
  });
  test('full image mask thresholding stays pixel aligned', () {
    final values = Float32List(512 * 512);
    values[100 * 512 + 200] = 0.75;
    values[100 * 512 + 201] = 0.5;
    values[100 * 512 + 202] = 0.49;
    final mask = MaskPostprocessor.projectMask(
      values,
      512,
      512,
      const Rect.fromLTWH(0, 0, 512, 512),
      const ModelConfig(),
    );
    expect(mask[100 * 512 + 200], 1);
    expect(mask[100 * 512 + 201], 1);
    expect(mask[100 * 512 + 202], 0);
    expect(mask.fold<int>(0, (a, b) => a + b), 2);
  });
  test(
    'ROI mask projects only into its box, with no whole-image stretching',
    () {
      final mask = MaskPostprocessor.projectMask(
        [1, 0, 0, 1],
        2,
        2,
        const Rect.fromLTWH(100, 150, 2, 2),
        const ModelConfig(maskSpace: MaskSpace.roi),
      );
      expect(mask[150 * 512 + 100], 1);
      expect(mask[151 * 512 + 101], 1);
      expect(mask[150 * 512 + 101], 0);
      expect(mask.fold<int>(0, (a, b) => a + b), 2);
    },
  );
  test('off-image ROI retains original coordinate mapping', () {
    final mask = MaskPostprocessor.projectMask(
      [0, 1, 0, 1],
      2,
      2,
      const Rect.fromLTWH(-1, 0, 2, 2),
      const ModelConfig(maskSpace: MaskSpace.roi),
    );
    expect(mask[0], 1);
    expect(mask[512], 1);
    expect(mask[1], 0);
  });
  test('ROI bilinear interpolation and logits', () {
    final mask = MaskPostprocessor.projectMask(
      [-10, 10, -10, 10],
      2,
      2,
      const Rect.fromLTWH(0, 0, 4, 4),
      const ModelConfig(maskSpace: MaskSpace.roi, maskLogits: true),
    );
    expect(mask[1 * 512 + 1], 0);
    expect(mask[1 * 512 + 2], 1);
    expect(mask[1 * 512 + 4], 0);
  });
  test('bounding-box formats and normalized coordinates', () {
    expect(
      MaskPostprocessor.convertBox([10, 20, 30, 40], const ModelConfig()),
      const Rect.fromLTRB(10, 20, 30, 40),
    );
    expect(
      MaskPostprocessor.convertBox([
        10,
        20,
        30,
        40,
      ], const ModelConfig(boxFormat: BoxFormat.xywh)),
      const Rect.fromLTRB(10, 20, 40, 60),
    );
    expect(
      MaskPostprocessor.convertBox([
        20,
        10,
        40,
        30,
      ], const ModelConfig(boxFormat: BoxFormat.yxyx)),
      const Rect.fromLTRB(10, 20, 30, 40),
    );
    expect(
      MaskPostprocessor.convertBox([
        0.25,
        0.5,
        0.75,
        1,
      ], const ModelConfig(normalizedBoxes: true)),
      const Rect.fromLTRB(128, 256, 384, 512),
    );
  });
  test('decode retains score/class/area/distance rejection reasons', () {
    final masks = Float32List(2 * 512 * 512);
    masks[0] = 1;
    masks[512 * 512 + 256 * 512 + 256] = 1;
    final result = MaskPostprocessor.decode(
      {
        'boxes': const ModelTensor(
          [2, 4],
          [0, 0, 512, 512, 0, 0, 512, 512],
          'float32',
        ),
        'scores': const ModelTensor([2], [0.1, 0.9], 'float32'),
        'labels': const ModelTensor([2], [2, 1], 'int64'),
        'masks': ModelTensor([2, 1, 512, 512], masks, 'float32'),
      },
      conductorModelConfig,
      const Offset(256, 256),
    );
    expect(result, hasLength(2));
    expect(result.first.rejectionReasons, hasLength(4));
    expect(result.last.rejectionReasons.single, contains('Mask area'));
  });
  test('zero detections and malformed output contract', () {
    final outputs = {
      'boxes': const ModelTensor([0, 4], [], 'float32'),
      'scores': const ModelTensor([0], [], 'float32'),
      'labels': const ModelTensor([0], [], 'int64'),
      'masks': const ModelTensor([0, 1, 512, 512], [], 'float32'),
    };
    expect(
      MaskPostprocessor.decode(
        outputs,
        conductorModelConfig,
        const Offset(256, 256),
      ),
      isEmpty,
    );
    outputs['boxes'] = const ModelTensor([0, 5], [], 'float32');
    expect(
      () => MaskPostprocessor.decode(
        outputs,
        conductorModelConfig,
        const Offset(256, 256),
      ),
      throwsFormatException,
    );
  });
  test(
    'RGB float CHW preprocessing scales once, no duplicate model normalization',
    () {
      final image = img.Image(width: 512, height: 512)
        ..setPixelRgb(0, 0, 255, 128, 0);
      final input = ModelPreprocessor.prepare(
        img.encodePng(image),
        conductorModelConfig,
      );
      expect(input.values, isA<Float32List>());
      expect(input.shape, [1, 3, 512, 512]);
      expect(input.values[0], 1);
      expect(input.values[512 * 512], closeTo(128 / 255, 1e-6));
      expect(input.values[2 * 512 * 512], 0);
    },
  );
  test('HWC BGR uint8 and explicit mean/std normalization', () {
    final bytes = img.encodePng(
      img.Image(width: 512, height: 512)..setPixelRgb(0, 0, 255, 128, 0),
    );
    final hwc = ModelPreprocessor.prepare(
      bytes,
      const ModelConfig(
        layout: ChannelLayout.hwc,
        bgr: true,
        dataType: InputDataType.uint8,
        scale: 1,
        batchDimension: false,
      ),
    );
    expect(hwc.shape, [512, 512, 3]);
    expect(hwc.values.take(3), [0, 128, 255]);
    final normalized = ModelPreprocessor.prepare(
      bytes,
      const ModelConfig(mean: [0.5, 0, 0], std: [0.5, 1, 1]),
    );
    expect(normalized.values.first, 1);
  });
  test('invalid crop and unconfirmed model fail explicitly', () {
    expect(
      () => ModelPreprocessor.prepare(
        img.encodePng(img.Image(width: 511, height: 512)),
        conductorModelConfig,
      ),
      throwsFormatException,
    );
    expect(() => const ModelConfig().validate(), throwsStateError);
    expect(
      () => const ModelConfig(std: [0, 1, 1]).validate(requireContract: false),
      throwsArgumentError,
    );
  });
}
