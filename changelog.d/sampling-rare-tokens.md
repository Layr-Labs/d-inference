### Correct rare token sampling

Fix a Float32 rounding error in continuous batching that could cause GPT-OSS
20B and other models using the same sampler to emit extremely unlikely tokens
at nonzero temperatures.
