### Flint serving speedups

- Pin the SDK with Flint decode and prefill speedups: larger decode command buffers, fewer paged decode dispatches and uploads, a fused MoE expert combine, batched sliding-window prefill attention, and constrained decode chaining. Outputs are byte-identical to the previous build.
- Flint's protocol and stop constraints keep decode pipelined: the next step no longer waits for the host to build its mask, and repeated constraint states reuse a cached device mask.
- `RecursiveSI/flint-int4` now serves at the automatic paged width (8 concurrent requests) on M5 Pro, Max and Ultra.
