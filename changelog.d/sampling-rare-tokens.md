### Sampled output no longer picks tokens of almost no probability

- At a temperature above 0, the sampler could pick a token the model gives
  almost no probability (below 10⁻¹⁰), seen as a stray word or a fragment of
  another script mid-sentence. A Float32 rounding error in the sampler's random
  draw caused it, for every model served with continuous batching; GPT-OSS 20B,
  with its large vocabulary, showed it most.
- Sampled output for a request with a fixed `seed` can differ from earlier
  releases. Temperature 0 output does not change.
