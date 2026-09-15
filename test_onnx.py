import onnx

model = onnx.load("maskrcnn_conductor.onnx")
onnx.checker.check_model(model)

print("ONNX model is valid")