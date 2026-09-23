"""Convert Spiideo's MIT-licensed SoccerNet 2023 segmentation checkpoint.

Usage: python3 scripts/convert_pitch_model.py CHECKPOINT OUTPUT.mlpackage
The checkpoint is loaded as tensor data only; no downloaded Python is executed.
Training uses RGB / 255 (no ImageNet normalization). Channels: full field,
centre circle, penalty areas, penalty arcs, goal areas, vertical goals.
"""
import sys
import torch
import coremltools as ct
from torchvision.models.segmentation import deeplabv3_resnet50


class PitchRegions(torch.nn.Module):
    def __init__(self, checkpoint):
        super().__init__()
        self.model = deeplabv3_resnet50(weights=None, weights_backbone=None, num_classes=6)
        state = torch.load(checkpoint, map_location="cpu", weights_only=True)["state_dict"]
        self.model.load_state_dict({k.removeprefix("model."): v for k, v in state.items() if k.startswith("model.")})

    def forward(self, image):
        logits = self.model(image)["out"]
        return torch.nn.functional.avg_pool2d(torch.sigmoid(logits), 4)


if __name__ == "__main__":
    torch.set_num_threads(4)
    model = PitchRegions(sys.argv[1]).eval()
    example = torch.zeros(1, 3, 544, 960)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    converted = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=example.shape,
        scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="regions")], minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16)
    converted.author = "Spiideo AB; Core ML conversion by Camelot"
    converted.license = "MIT — Copyright (c) 2023 Spiideo AB"
    converted.short_description = "Soccer pitch regions for reviewable field-alignment proposals"
    converted.user_defined_metadata["source"] = "https://github.com/Spiideo/soccersegcal/releases/tag/SoccerNetChallenge2023"
    converted.save(sys.argv[2])
