### Faster Gemma 4 pipeline pairs

- Gemma 4 pipeline stages compute a prompt chunk's expert blocks in one shared dispatch per operation instead of one subgraph per prompt token, with the same bytes for every token (unchanged arithmetic receipt). Batch-decode rows share the same dispatch. On one synthetic expert layer this cut a 2,048-token chunk from about 370 ms to about 31 ms; pair throughput is not yet measured.
- A Gemma 4 pipeline pair whose setup prefills serially, coordinator-registered pairs included, now serves four requests at once. Each lane is admitted against live memory on both Macs. A pair planned with the one-chunk lookahead keeps serving one request at a time.
- The planner's hardware prior counts 8 of Gemma 4's 128 experts per token instead of every expert byte.
