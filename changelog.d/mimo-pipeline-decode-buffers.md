### MiMo pipeline decode command buffers and expert routing

- MiMo V2.6 Flash pairs encode decode steps, lane steps and speculative rounds
  in Metal command buffers of up to 100 operations with no input-size bound, as
  GLM and Qwen tensor parallel already do. Prefill keeps the rank's limits.
  Tokens, logits and caches are byte-identical on synthetic stages. The speed
  effect on the registered model has not been measured yet.
- A MiMo request's memory charge now prices every full-attention layer's decode
  score rows at once, which the larger command buffers can keep alive together.
  The LOAD quote is unchanged. Only requests whose prompt frames are shorter
  than a stage's full-attention layers times the decode rows (32 tokens at most)
  are charged slightly more.
- The planner's hardware prior now counts MiMo's routed experts at the 8 of 256
  a token uses: 10.77 GB read per decode step instead of 166.6 GB. MiMo has no
  tensor-parallel plan yet, so MiMo placements are unchanged.
