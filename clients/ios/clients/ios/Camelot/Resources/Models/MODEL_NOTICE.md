# Basketball Detector Attribution

The bundled `BasketballDetector.mlpackage` is derived from the E-BARD
`BODD_rf-detr-nano_0000/checkpoint_best_total.pth` checkpoint by Gabriele
Giudici:

https://huggingface.co/GabrieleGiudici/E-BARD-detection-models

The checkpoint is licensed under Creative Commons Attribution 4.0. The model
was converted to Core ML FP16, and its outputs were renamed to `boxes` and
`logits` for integration with Hoops. Checkpoint SHA-256:

`759968ecf8f83663c85de3d881713e072f4a9dd0ea2f136b082878b1e4fe2400`

RF-DETR and the RF-DETR-to-Core-ML converter are licensed under Apache 2.0.

