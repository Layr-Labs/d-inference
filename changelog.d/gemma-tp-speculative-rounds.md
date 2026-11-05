### Gemma tensor parallel: speculative rounds in the runtime (not served yet)

- The cluster runtime can decode Gemma 4 26B in speculative rounds on a tensor-parallel pair, with the same assistant drafter one Mac uses. Each verified token equals the plain tensor-parallel path's, greedy and sampled. Serving it through Darkbloom comes in a later release, after a measured speedup and a parity record.
