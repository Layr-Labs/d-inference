### GLM tensor-parallel prefill: faster bit-identical kernels

- GLM-5.3-Flash prompts prefill a little faster on a tensor-parallel pair: each hyper-connection site (89 per forward on both Macs) computes the expanded residual streams inside the products that read them, about 9 % faster per site, roughly 5 ms per 4,096 prompt tokens. Outputs are bit-identical.
