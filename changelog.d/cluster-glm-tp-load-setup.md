### GLM tensor-parallel setup reads metadata once, beside the link

- A GLM-5.3-Flash tensor-parallel rank parses its model metadata once (the prepared loader's inventory) and does that work on its own thread while the link comes up, instead of serially before it; tensor-name matching runs on bytes. Setup before the load intent drops from about 5.7 s to about 3 s a rank, and `open` to about 0. Loaded weights are byte-identical and every file is still hashed.
