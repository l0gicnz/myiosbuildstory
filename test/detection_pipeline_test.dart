import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:powerline_measure/ml/conductor_detection.dart';
import 'package:powerline_measure/ml/detection_selector.dart';
import 'package:powerline_measure/ml/detection_store.dart';
import 'package:powerline_measure/ml/mask_postprocessor.dart';
import 'package:powerline_measure/ml/model_config.dart';

Map<String, ModelTensor> validOutputs() {
  final masks = Float32List(2 * 512 * 512);
  for (var y = 100; y < 110; y++) {
    masks[y * 512 + 100] = 1;
    masks[512 * 512 + y * 512 + 120] = 1;
  }
  return {
    'boxes': const ModelTensor(
      [2, 4],
      [100, 100, 101, 110, 120, 100, 121, 110],
      'float32',
    ),
    'scores': const ModelTensor([2], [0.7, 0.99], 'float32'),
    'labels': const ModelTensor([2], [1, 1], 'int64'),
    'masks': ModelTensor([2, 1, 512, 512], masks, 'float32'),
  };
}

void main() {
  test(
    'decoded conductor masks retain coordinates and select the tapped instance',
    () {
      final detections = MaskPostprocessor.decode(
        validOutputs(),
        conductorModelConfig,
        const Offset(100, 105),
      );
      expect(detections.every((d) => d.isValid), isTrue);
      expect(detections.first.maskArea, 10);
      expect(detections.last.distanceFromSelectedPoint, 20);
      expect(DetectionSelector.select(detections, 32), same(detections.first));
      expect(detections.first.binaryMask[105 * 512 + 100], 1);
      expect(detections.first.binaryMask[105 * 512 + 120], 0);
    },
  );

  test('unexpected output types fail with a useful contract error', () {
    final outputs = validOutputs();
    outputs['scores'] = const ModelTensor([2], [1, 1], 'int64');
    expect(
      () => MaskPostprocessor.decode(
        outputs,
        conductorModelConfig,
        const Offset(100, 105),
      ),
      throwsFormatException,
    );
  });

  test('acceptance saves exact binary mask and crop coordinates', () async {
    final directory = await Directory.systemTemp.createTemp(
      'powerline_accept_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final detections = MaskPostprocessor.decode(
      validOutputs(),
      conductorModelConfig,
      const Offset(100, 105),
    );
    final result = ConductorDetectionResult(
      detections: detections,
      selectedDetection: detections.first,
      inferenceTime: const Duration(milliseconds: 123),
      totalTime: const Duration(milliseconds: 150),
      selectedPoint: const Offset(100, 105),
    );
    final path = '${directory.path}/crop.png';
    await DetectionStore.save(path, result, {'cropX': 300, 'cropY': 500});
    final mask = img.decodePng(
      await File('$path.accepted-mask.png').readAsBytes(),
    )!;
    expect((mask.width, mask.height), (512, 512));
    expect(mask.getPixel(100, 105).r, 255);
    expect(mask.getPixel(120, 105).r, 0);
    final metadata =
        jsonDecode(await File('$path.accepted.json').readAsString()) as Map;
    expect(metadata['cropX'], 300);
    expect(metadata['selectedCropX'], 100);
    expect(metadata['selectedCropY'], 105);
    expect(metadata['inferenceMilliseconds'], 123);
    expect(metadata['boxXYXY'], [100, 100, 101, 110]);
  });
}
