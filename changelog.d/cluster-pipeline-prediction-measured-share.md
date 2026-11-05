### Two-Mac cluster: a pipeline is no longer predicted faster than a share its Mac measured

- On two M5 Ultras the mode question recommended Gemma 4 26B's pipeline, "about 183 against 107 tokens/s,
  predicted"; 59.9 and 105.1 tok/s were served. Until a model has been measured whole on a Mac, its pipeline speed
  came from the Mac's device index alone, which leaves out every per-token cost. Where the Mac has measured a share of
  the model (a tensor-parallel load's share probe, or requests served in tensor parallel), the whole model is now
  planned at least as slow as that share plus the rest of its weights, so tensor parallel is recommended there.
