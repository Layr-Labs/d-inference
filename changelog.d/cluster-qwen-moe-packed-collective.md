### Pack Qwen MoE tensor-parallel expert and shared reductions

Qwen routed-expert tensor parallelism now carries the shared expert's float32
partial in the routed experts' collective: two collectives per layer instead of
three, with every summed and rounded value unchanged. The load agreement
(`qwen-moe-down-projections-f32-sum-before-weighting-packed-v3`) and the
tensor-parallel check's launch version refuse mixed builds. Placement now
charges the top-K expert rows once per layer instead of the largest payload on
every collective, and the request ledger charges the packed payload's source
partials. Full-model hardware qualification on the pair is still required.
