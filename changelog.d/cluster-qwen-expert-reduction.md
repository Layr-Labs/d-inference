### Sum Qwen tensor-parallel expert projections before router weighting

Qwen routed-expert tensor parallelism now sums float32 expert and shared-expert
down projections separately before rounding, router weighting and shared gating.
The load agreement distinguishes the new arithmetic from earlier workers.
Placement and native admission account for top-K collective payloads and the
complete request ledger. This correction still requires full-model hardware
qualification; it does not establish support for additional model families.
