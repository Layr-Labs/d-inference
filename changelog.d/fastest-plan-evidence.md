### Tensor parallel for Gemma 4 and MiMo only on measured speed

- Gemma 4 and MiMo V2.6 Flash pairs choose tensor parallel only once tensor parallel's own speed is measured on both Macs: each Mac's half timed by a tensor-parallel load (Gemma), or requests this Darkbloom build served in tensor parallel. An estimate from the Macs' device index alone no longer chooses it, because the index overstates what half a model saves on big Macs: on two M5 Ultra it predicts a short Gemma request 6% faster in tensor parallel, where the plans expect decode 6-8% slower.
- When the estimate says tensor parallel would be faster, the pair keeps the pipeline. The plan's "Tensor parallel or pipeline" line says the predicted gain and that it comes from the device index, and the model list says "tensor parallel: not measured yet".
- Normal setups do not load tensor parallel to measure it, so these pairs keep the pipeline for now. MiMo does not yet time its halves at load, so MiMo pairs reach tensor parallel only from requests the same build served in tensor parallel.
- Qwen and GLM still choose tensor parallel wherever it fits.
