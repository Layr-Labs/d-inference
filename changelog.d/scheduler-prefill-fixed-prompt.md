### Fixed-input scheduler-prefill benchmarks

- Add opt-in `benchmark --scheduler-prefill --prefill-fixed-prompt` to repeat seed offset zero for warmup and measured iterations. Default measured prompts retain their rotation; other benchmark modes reject the flag.
- Record prompt mode, warmup offset and per-sample offsets in backward-compatible optional report fields. Fresh engines, disabled prefix caching and the existing prefill stripe remain unchanged.
- Initialize the serving allocator limits before scheduler-prefill model loading and log the applied cache limit, matching the throughput sweep and serving paths.
