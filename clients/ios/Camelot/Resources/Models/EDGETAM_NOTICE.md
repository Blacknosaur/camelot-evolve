# EdgeTAM

`edgetam_image_encoder.mlpackage`, `edgetam_prompt_encoder.mlpackage` and
`edgetam_mask_decoder.mlpackage` are converted
from [EdgeTAM](https://github.com/facebookresearch/EdgeTAM) (Meta), Apache
License 2.0 — which covers both the code and the released checkpoints.

Converted from `checkpoints/edgetam.pt` with the repository's own
`coreml/export_to_coreml.py`, with two local fixes needed for the conversion to
complete. Both were checked to be numerically identical (max abs diff 0.0)
before use:

1. The export script's image-encoder wrapper unpacked `vision_features.shape`
   into Python ints and viewed back, only so `no_mem_embed` could be added.
   Under `torch.jit.trace` that becomes `aten::Int`, which coremltools rejects.
   Broadcasting the embedding as `(1, C, 1, 1)` is the same arithmetic.
2. `sam2/modeling/sam/mask_decoder.py` built masks as
   `(hyper_in @ upscaled_embedding.view(b, c, h * w)).view(b, -1, h, w)`.
   Rewritten as `torch.einsum("bqc,bchw->bqhw", ...)`, which needs no dimension
   to become a Python scalar.

## Dead inputs, verified on the converted models

Two of the mask decoder's declared inputs are ignored, because the upstream
wrapper resolves them inside the traced graph rather than from the input:

- `image_pe` — the wrapper calls `sam_prompt_encoder.get_dense_pe()` itself, so
  the positional encoding is baked in. Pass zeros. (Feeding random values of ten
  times the magnitude changes nothing: verified byte-identical output.)
- `multimask_output` — resolved by `.item()` at trace time, so the model always
  returns three masks and three IoU predictions whatever is passed. Choose the
  mask by `argmax(iou_pred)`.

The prompt encoder likewise ignores its `boxes` and `mask_input` inputs: the
wrapper passes `boxes=None, masks=None` and uses only the points. A box prompt
is therefore expressed the way SAM 2 does internally — two corner points
labelled 2 (top-left) and 3 (bottom-right).

**These three models are the image path only.** EdgeTAM's temporal memory
(`memory_attention`, `memory_encoder`, `spatial_perceiver`) is present in the
checkpoint but is *not* exported by the upstream script, so on their own these
give promptable per-frame segmentation, not video object segmentation with
memory. `PlayerTemporalSegmenter.carriesTemporalMemory` reports which is running
so the two are never confused in a benchmark.
