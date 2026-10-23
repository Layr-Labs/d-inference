### Qwen3.6 mixed routing gates in tensor parallel

- Load the registered Qwen3.6 35B A3B text target on two equal tensor-parallel shares while preserving its replicated affine8 routing gates and affine4 expert projections. Verified artifact identity, memory gates and numerical acceptance rules remain required; vision and MTP are excluded from this mode.
