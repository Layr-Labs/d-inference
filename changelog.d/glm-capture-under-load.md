### GLM prefix checkpoints under load

- GLM-5.3-Flash now captures a repeated prompt's checkpoints while other requests are decoding. Their decode tokens shortened every prefill chunk below 2,048, so no chunk ended on the 256-token checkpoint grid and the donor was silently not cached (one of six donors in a concurrent burst on an M5 Ultra). A donor the cache will write now ends a prefill range at its demanded boundaries whatever its company; in the same burst six of six were captured and written.
- GLM checkpoints now land on any 256-token boundary instead of every 2,048: a 32,682-token prompt restores 32,512 tokens instead of 30,720 (hit time to first token 3.1–3.7 s, was about 4.0 s).
- A GLM cache hit served beside decoding requests no longer waits for a full 2,048-token chunk and cold-restarts after three waits; it resumes under ordinary chunking.
