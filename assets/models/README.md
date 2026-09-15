# Supplied conductor model

`maskrcnn_conductor.onnx` is the real user-supplied model, copied unchanged from the project root.

- SHA-256: `c7308631345c8237f09350d4442e969828fdcc152fde6053b4696d6700a85df5`
- Size: 176,165,077 bytes
- Producer: PyTorch 2.4.1; ONNX opset 18
- Input: `image`, float32 `[1,3,512,512]`, RGB in [0,1]
- Outputs: `boxes` float32 `[N,4]` XYXY in crop pixels; `labels` int64 `[N]`; `scores` float32 `[N]`; `masks` float32 `[N,1,512,512]` probabilities
- Classifier/mask heads have two channels: background 0 and sole foreground 1 (conductor).
- Graph begins with mean `[0.485,0.456,0.406]` subtraction and std `[0.229,0.224,0.225]` division. These operations must NOT be duplicated in Flutter.
- Graph also internally resizes using minimum size 800 / maximum 1333, then projects results back to the original 512-square input. The Flutter code does not resize inputs or the returned masks.
- A black-crop desktop CPU smoke run returned zero detections with masks shape `[0,1,512,512]`.
- The Android 16/API 36 x86_64 emulator integration test passed two black-crop runs in the same session, reporting `[0,1,512,512]` masks and clean disposal (7,777 ms and 5,371 ms).

Configuration lives in `lib/ml/model_config.dart`. If replacing this model, inspect its metadata and graph first and update the contract. Numeric names alone cannot establish channel order, normalization, or box/mask semantics.

No real validation photographs were provided. Black-image smoke tests establish runtime/empty-output handling, not accuracy or alignment of positive detections on photographs.
