import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'model_config.dart';

class PreparedInput {
  const PreparedInput(this.values, this.shape);
  final List<num> values;
  final List<int> shape;
}

class ModelPreprocessor {
  static PreparedInput prepare(Uint8List bytes, ModelConfig config) {
    config.validate(requireContract: false);
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('Cannot decode crop.');
    final image = img
        .bakeOrientation(decoded)
        .convert(numChannels: 3, format: img.Format.uint8);
    if (image.width != config.width || image.height != config.height) {
      throw FormatException(
        'Expected ${config.width} × ${config.height} crop; '
        'received ${image.width} × ${image.height}. Retake at full resolution.',
      );
    }
    final count = image.width * image.height;
    final List<num> values = config.dataType == InputDataType.float32
        ? Float32List(count * 3)
        : Uint8List(count * 3);
    for (final pixel in image) {
      final rgb = config.bgr
          ? [pixel.b, pixel.g, pixel.r]
          : [pixel.r, pixel.g, pixel.b];
      final position = pixel.y * image.width + pixel.x;
      for (var channel = 0; channel < 3; channel++) {
        final index = config.layout == ChannelLayout.chw
            ? channel * count + position
            : position * 3 + channel;
        final normalized =
            (rgb[channel] * config.scale - config.mean[channel]) /
            config.std[channel];
        if (values is Uint8List) {
          values[index] = normalized.toInt();
        } else {
          values[index] = normalized;
        }
      }
    }
    return PreparedInput(values, config.inputShape);
  }
}
