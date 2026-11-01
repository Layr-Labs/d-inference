### Faster Gemma 4 pipeline pairs

- Gemma 4 pipeline stages compute a prompt chunk's expert blocks in one shared dispatch per operation instead of one subgraph per prompt token, with the same bytes for every token (unchanged arithmetic receipt). Batch-decode rows share the same dispatch. On one synthetic expert layer this cut a 2,048-token chunk from about 350 ms to about 37 ms; pair throughput is not yet measured.
