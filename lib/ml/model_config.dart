enum ChannelLayout { chw, hwc }

enum InputDataType { float32, uint8 }

enum BoxFormat { xyxy, xywh, yxyx }

enum MaskSpace { fullImage, roi }

/// Export-specific settings must be confirmed against the supplied model.
class ModelConfig {
  const ModelConfig({
    this.assetPath = 'assets/models/maskrcnn_conductor.onnx',
    this.confirmed = false,
    this.inputName,
    this.boxesName,
    this.scoresName,
    this.labelsName,
    this.masksName,
    this.width = 512,
    this.height = 512,
    this.layout = ChannelLayout.chw,
    this.dataType = InputDataType.float32,
    this.batchDimension = true,
    this.bgr = false,
    this.scale = 1 / 255,
    this.mean = const [0, 0, 0],
    this.std = const [1, 1, 1],
    this.boxFormat = BoxFormat.xyxy,
    this.normalizedBoxes = false,
    this.maskSpace = MaskSpace.fullImage,
    this.maskLogits = false,
    this.maskChannel = 0,
    this.maskChannelFromLabel = false,
    this.conductorClassIds = const [],
    this.minimumConfidence = 0.5,
    this.maskThreshold = 0.5,
    this.maximumPointDistance = 32,
    this.minimumMaskArea = 8,
  });
  final String assetPath;
  final bool confirmed;
  final String? inputName, boxesName, scoresName, labelsName, masksName;
  final int width, height, maskChannel, minimumMaskArea;
  final ChannelLayout layout;
  final InputDataType dataType;
  final bool batchDimension,
      bgr,
      normalizedBoxes,
      maskLogits,
      maskChannelFromLabel;
  final double scale, minimumConfidence, maskThreshold, maximumPointDistance;
  final List<double> mean, std;
  final BoxFormat boxFormat;
  final MaskSpace maskSpace;
  final List<int> conductorClassIds;

  List<int> get inputShape => [
    if (batchDimension) 1,
    if (layout == ChannelLayout.chw) 3,
    height,
    width,
    if (layout == ChannelLayout.hwc) 3,
  ];

  void validate({bool requireContract = true}) {
    if (requireContract &&
        (!confirmed ||
            [
              inputName,
              boxesName,
              scoresName,
              masksName,
            ].any((v) => v == null || v.isEmpty))) {
      throw StateError(
        'Model contract is unconfirmed. Inspect the logged ONNX metadata and configure '
        'tensor names, preprocessing, classes and mask space in lib/ml/model_config.dart.',
      );
    }
    if (width != 512 || height != 512) {
      throw ArgumentError(
        'Phase 2 requires a 512 × 512 model input; resizing is not enabled.',
      );
    }
    if (mean.length != 3 ||
        std.length != 3 ||
        mean.any((v) => !v.isFinite) ||
        std.any((v) => !v.isFinite || v <= 0) ||
        !scale.isFinite ||
        scale <= 0 ||
        !minimumConfidence.isFinite ||
        minimumConfidence < 0 ||
        minimumConfidence > 1 ||
        !maskThreshold.isFinite ||
        maskThreshold <= 0 ||
        maskThreshold > 1 ||
        !maximumPointDistance.isFinite ||
        maximumPointDistance < 0 ||
        minimumMaskArea < 1 ||
        maskChannel < 0) {
      throw ArgumentError('Invalid preprocessing or detection thresholds.');
    }
    if (dataType == InputDataType.uint8 &&
        (scale != 1 || mean.any((v) => v != 0) || std.any((v) => v != 1))) {
      throw ArgumentError('uint8 input requires scale=1, mean=0, std=1.');
    }
    if ((conductorClassIds.isNotEmpty || maskChannelFromLabel) &&
        labelsName == null) {
      throw ArgumentError(
        'Class filtering/channel selection requires a labels tensor.',
      );
    }
  }
}

// Inspected PyTorch 2.4.1 export, opset 18. The graph performs ImageNet
// mean/std normalization and internal resizing itself; do not repeat it here.
// Two classifier channels: background 0 and the sole foreground/conductor 1.
const conductorModelConfig = ModelConfig(
  confirmed: true,
  inputName: 'image',
  boxesName: 'boxes',
  scoresName: 'scores',
  labelsName: 'labels',
  masksName: 'masks',
  conductorClassIds: [1],
);
