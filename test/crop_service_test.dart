import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:powerline_measure/image_processing/crop_service.dart';

void main() {
  for (final dimensions in [(4000, 3000), (3000, 4000)]) {
    final (w, h) = dimensions;
    group('$w × $h', () {
      final cases = <String, (double, double, int, int)>{
        'centre': (w / 2, h / 2, w ~/ 2 - 256, h ~/ 2 - 256),
        'top': (w / 2, 0, w ~/ 2 - 256, 0),
        'bottom': (w / 2, h - 1.0, w ~/ 2 - 256, h - 512),
        'left': (0, h / 2, 0, h ~/ 2 - 256),
        'right': (w - 1.0, h / 2, w - 512, h ~/ 2 - 256),
        'top left': (0, 0, 0, 0),
        'top right': (w - 1.0, 0, w - 512, 0),
        'bottom left': (0, h - 1.0, 0, h - 512),
        'bottom right': (w - 1.0, h - 1.0, w - 512, h - 512),
      };
      for (final entry in cases.entries) {
        test(entry.key, () {
          final (x, y, cx, cy) = entry.value;
          final s = CropService.calculate(width: w, height: h, x: x, y: y);
          expect((s.cropX, s.cropY), (cx, cy));
          expect((s.cropWidth, s.cropHeight), (512, 512));
          expect((s.selectedX, s.selectedY), (x.floor(), y.floor()));
          expect((s.sourceWidth, s.sourceHeight), (w, h));
        });
      }
    });
  }
  test('small source and exact 512 source', () {
    final s = CropService.calculate(width: 320, height: 800, x: 12, y: 400);
    expect((s.cropX, s.cropY, s.cropWidth, s.cropHeight), (0, 144, 320, 512));
    final exact = CropService.calculate(
      width: 512,
      height: 512,
      x: 511,
      y: 511,
    );
    expect((exact.cropX, exact.cropY), (0, 0));
  });
  test('fractional taps select containing pixel; invalid inputs rejected', () {
    final s = CropService.calculate(
      width: 1000,
      height: 1000,
      x: 500.9,
      y: 600.2,
    );
    expect((s.selectedX, s.selectedY, s.cropX, s.cropY), (500, 600, 244, 344));
    expect(
      () => CropService.calculate(width: 0, height: 100, x: 0, y: 0),
      throwsArgumentError,
    );
    expect(
      () => CropService.calculate(width: 100, height: 100, x: double.nan, y: 0),
      throwsArgumentError,
    );
  });
  test(
    'orientation, preserved original, exact crop pixels and metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('powerline_test_');
      addTearDown(() => dir.delete(recursive: true));
      final original = img.Image(width: 600, height: 800);
      for (final p in original) {
        p.setRgb(p.x % 256, p.y % 256, (p.x + p.y) % 256);
      }
      original.exif.imageIfd.orientation = 6;
      final bytes = img.encodeJpg(original, quality: 95);
      final file = File('${dir.path}/original.jpg')..writeAsBytesSync(bytes);
      final source = await CropService.prepare(file.path);
      expect((source.width, source.height), (800, 600));
      expect(file.readAsBytesSync(), bytes);
      final expected = img.bakeOrientation(img.decodeJpg(bytes)!);
      final s = CropService.calculate(
        width: source.width,
        height: source.height,
        x: 790,
        y: 590,
      );
      final path = await CropService.extract(
        source,
        s,
        jobName: 'Pole 12',
        location: {
          'latitude': -36.8485,
          'longitude': 174.7633,
          'accuracyMetres': 4.5,
        },
      );
      final crop = img.decodePng(File(path).readAsBytesSync())!;
      expect((crop.width, crop.height), (512, 512));
      for (final p in crop) {
        final e = expected.getPixel(p.x + s.cropX, p.y + s.cropY);
        if (p.r != e.r || p.g != e.g || p.b != e.b) {
          fail('Pixel mismatch at ${p.x}, ${p.y}');
        }
      }
      final metadata = jsonDecode(File('$path.json').readAsStringSync()) as Map;
      for (final entry in s.toJson().entries) {
        expect(metadata[entry.key], entry.value);
      }
      expect(metadata['jobName'], 'Pole 12');
      expect(metadata['location']['latitude'], -36.8485);
      expect(metadata['location']['longitude'], 174.7633);
    },
  );
}
