# Powerline Measure - Phases 1 and 2

Android camera capture, source-pixel inspection, and on-device conductor segmentation using the supplied Mask R-CNN ONNX model. Diameter measurement is not implemented.

## Run on an Android phone

1. Enable Developer options and USB debugging, connect by USB, and accept the phone's debugging prompt.
2. Run `flutter devices` and identify the phone ID.
3. Run `flutter run -d <phone-id>` and grant camera permission.
4. Take a photo, pinch to zoom, drag to pan, and tap a conductor.
5. The cyan marker selects a pixel; the amber rectangle shows the actual clamped crop.
6. Open crop to inspect the saved PNG. Go back to select again, or use Retake.
7. Press **Analyse Conductor**. The selected mask, bounding box, confidence and inference time appear over/under the crop.
8. Use **Analyse Again**, **Accept Detection**, or **Retap**. Acceptance saves the binary mask and metadata alongside the crop and stays on the inspection screen.

## Model and inference

The real model is bundled at `assets/models/maskrcnn_conductor.onnx`. Its inspected contract and fingerprint are documented in [assets/models/README.md](assets/models/README.md).

`lib/ml/model_config.dart` configures names, shape, RGB/BGR order, CHW/HWC layout, datatype, normalization, output mask space, box format, class IDs and thresholds. The supplied model uses RGB float32 `[1,3,512,512]` in [0,1]. Its graph already performs mean/std normalization and internal resizing. The app never resizes the crop or applies normalization twice.

ONNX Runtime runs locally through `flutter_onnxruntime`; no network API is used. Preprocessing and mask decoding run in Dart isolates, and the Android plugin runs native calls on a background queue. A session is reused for repeated analysis; native tensors are released after every inference and the session closes when leaving the crop screen. Displayed inference time covers the runtime call; total time also includes preprocessing and output decoding but excludes initial model loading.

The inspected model returns boxes `[N,4]`, scores/labels `[N]` and full-crop probability masks `[N,1,512,512]`. Full-crop masks are thresholded without resizing. A separately configured ROI-mask path supports bilinear projection through the original bounding box, including boxes extending beyond the crop; it is not used by this export.

Selection uses `(selectedSourceX - cropX, selectedSourceY - cropY)`, so boundary-clamped crops work correctly. A mask containing that point wins, with confidence breaking ties. Otherwise the nearest foreground mask pixel wins within the configured distance. Defaults: confidence 0.5, mask threshold 0.5, maximum distance 32 pixels, minimum area 8 pixels, conductor class 1.

Debug builds expose **Debug: all detections**, including masks, boxes, scores, class, selected status and rejection reasons. Model input/output names, types and shapes are logged and shown in this panel. These are all detections returned by the exported graph; proposals removed inside the model cannot be recovered by the app.

Missing assets, incompatible tensor contracts, invalid crops and runtime failures produce explicit errors. Crops smaller than 512 in either dimension remain inspectable but cannot be analysed by this fixed-size model.

Acceptance writes `.accepted-mask.png` (512-square, 0/255 pixels) and `.accepted.json` with source/crop coordinates, confidence, class, bounding box, mask area and timing. Reaccepting a new result for the same crop replaces that crop's accepted result.

## Image and coordinate contract

- Uses camera `takePicture()` with `ResolutionPreset.max`, audio disabled, and the rear camera when available. Actual capture resolution depends on device hardware and the camera backend.
- Copies the unmodified camera file into the app documents `captures/` directory before processing.
- Bakes EXIF rotation/mirroring into a full-resolution lossless PNG in a background isolate. No resizing is used. Coordinates refer to this upright source (width/height swap for a quarter turn), not the encoded JPEG's unrotated raster.
- The inspection image and crop both use that same PNG. Display fitting preserves aspect ratio. Tap mapping inverts the viewer transform, removes letterbox offsets, and divides by the fitted image scale. Letterbox taps are ignored.
- Coordinates are zero-based integers; fractional taps select the containing pixel. The marker is at that pixel's centre. Crop origin is selected pixel minus 256, clamped to the source bounds.
- Crops are exactly 512 x 512 when both source dimensions permit. Smaller sources use the available dimension without padding or upscaling, with an explicit UI notice.
- Opening a crop saves a PNG plus `.png.json` containing source dimensions, selected X/Y, crop X/Y/width/height, and file paths. Retaking does not delete earlier files. App-private files persist across restarts but are removed when app data is cleared or the app is uninstalled. There is no gallery/history UI in Phase 1.
- Full-resolution processing uses memory proportional to photograph size and can take several seconds on phones.

## Checks

```sh
dart format .
flutter analyze
flutter test
flutter test integration_test/onnx_smoke_test.dart -d <android-device-id>
flutter build apk --debug
```

Tests cover all edges/corners and centre in portrait and landscape, small sources, fractional taps, letterboxing, transformed taps, drag rejection, EXIF orientation, exact crop pixels, and saved metadata.

Phase 2 tests cover tap containment, competing masks, nearest-mask selection, distance rejection, thresholding, ROI projection, box formats, crop-relative taps, output validation and RGB preprocessing. The integration test uses the real model on a black crop and repeats inference to check session reuse and empty outputs. It does not establish detection accuracy on photographs.

Verified on 15 September 2026: `dart format .`, `flutter analyze`, all 43 unit/widget tests, and the Android debug APK build passed. The real-model integration test passed on an Android 16/API 36 x86_64 emulator, including two runs in the same session and cleanup. The runs took 7,777 ms and 5,371 ms; these are emulator smoke-test timings, not phone benchmarks. Physical-phone and positive real-photo validation remain outstanding.

## Physical-device acceptance

Check portrait and landscape photos, pinch/pan then tap recognisable details, every edge/corner, selection updates, crop preview, repeated retakes, background/resume, and denied permission followed by retry. Compare displayed crop coordinates against its JSON. Device camera behaviour and high-resolution memory use require real-phone verification.

Phase 2 real-photo acceptance remains pending: no validation crops were supplied. Test a single conductor through the centre, multiple conductors, taps on/beside a conductor, no conductor, an edge conductor, a thin conductor, and a large/close conductor. Confirm overlay alignment while zooming, correct instance selection, clean no-detection messages, repeat analysis and acceptance. The automated synthetic-mask tests do not substitute for these checks.

## Platform scope

Android is the primary target. Camera permission text is included for iOS and the Dart camera/storage/processing code also supports iOS; iOS compilation and testing require macOS/Xcode. Desktop and web camera support are not part of Phase 1.

The ONNX plugin supports iOS 16 and later through its Apple backend. The iOS target is set to 16.0. iOS compilation and physical-device testing require a macOS/Xcode build environment.

Package references: https://pub.dev/packages/camera and https://pub.dev/documentation/image/latest/image/bakeOrientation.html
