import torch
import torchvision


class MaskRCNNWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        # image arrives as [1, 3, 512, 512]
        result = self.model([image[0]])[0]

        return (
            result["boxes"],
            result["labels"],
            result["scores"],
            result["masks"],
        )


MODEL_PATH = "maskrcnn_conductor.pth"
ONNX_PATH = "maskrcnn_conductor.onnx"

NUM_CLASSES = 2

model = torchvision.models.detection.maskrcnn_resnet50_fpn(
    weights=None,
    weights_backbone=None,
    num_classes=NUM_CLASSES,
)

checkpoint = torch.load(MODEL_PATH, map_location="cpu")

if isinstance(checkpoint, dict) and "model_state_dict" in checkpoint:
    checkpoint = checkpoint["model_state_dict"]

model.load_state_dict(checkpoint)
model.eval()

wrapped_model = MaskRCNNWrapper(model)
wrapped_model.eval()

dummy = torch.rand(1, 3, 512, 512)

torch.onnx.export(
    wrapped_model,
    dummy,
    ONNX_PATH,
    opset_version=18,
    input_names=["image"],
    output_names=[
        "boxes",
        "labels",
        "scores",
        "masks",
    ],
)

print("Export complete")