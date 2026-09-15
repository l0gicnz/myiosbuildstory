import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:powerline_measure/ml/conductor_detector.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real asset loads on device and runs twice with empty detections',
    (tester) async {
      final detector = ConductorDetector();
      try {
        await detector.initialise();
        final crop = img.encodePng(img.Image(width: 512, height: 512));
        for (var i = 0; i < 2; i++) {
          final result = await detector.analyse(crop, const Offset(256, 256));
          expect(result.selectedDetection, isNull);
          expect(result.detections, isEmpty);
          expect(result.inferenceTime.inMicroseconds, greaterThan(0));
        }
      } finally {
        await detector.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
