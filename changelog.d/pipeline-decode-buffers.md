### Pipeline decode command buffers for the remaining cluster models

- Pipeline pairs of the Qwen 3.5/3.6 and Bonsai rows, Nemotron 3.5 Lightning,
  Gemma 4, GPT-OSS 20B and GLM-5.3-Flash encode decode steps, lane steps and
  speculative rounds in Metal command buffers of up to 100 operations with no
  input-size bound, as GLM and Qwen tensor parallel already do. Prefill keeps
  the rank's limits. Tokens, logits and caches are byte-identical on synthetic
  stages. The speed effect on registered models has not been measured yet, and
  each family keeps the change only if a pair A/B shows a gain.
- A request's memory charge on those pipelines now prices every attending
  layer's decode rows at once, which the larger command buffers can keep alive
  together. The LOAD quotes are unchanged. Only requests whose prompt frames are
  shorter than their decode rows (at most 80) are charged slightly more.
