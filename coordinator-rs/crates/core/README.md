# Coordinator core

This crate contains deterministic domain policy with no I/O:

- validated IDs, revisions, deadlines, token quantities, and micro-USD values;
- a pure request reducer with replay identity, provider revision fencing,
  bounded primary/alternate/hedge attempts, resource conservation, and one
  terminal accounting disposition;
- immutable fleet snapshots, exact admission checks, stable integer scoring,
  circuit health, and bounded model/hardware calibration;
- checked pricing and request/provider trait compatibility.

## TTFT routing contract replay

`tests/routing_replay.rs` consumes
`tests/contracts/routing/ttft_calibration.json`. Schema v2 contains every
deterministic synthetic arrival, provider throughput inputs, capacity limits,
Go candidate/rejection counts, best TTFT, deadline, expected outcome, and the
expected stable first-ranked provider. Shared arrival inputs are stored once;
repeated scenario decisions use lossless run-length encoding. The fixture
also contains deterministic multi-provider scoring cases whose expected
provider IDs and indices are captured from real Go `ReserveProviderEx`
executions. It contains token counts only and no prompt or response content.

The Rust replay deserializes every decision, constructs validated provider
snapshots, runs trait and token/KV/concurrency admission, predicts TTFT with
checked integer arithmetic, applies the hard or soft TTFT gate, and executes
stable cost ranking. It compares every outcome and winner to the fixture and
reports candidate, rank, and outcome changes plus prediction error across the
legacy ratio, calibrated ratio, and soft-gate scenarios. The scoring cases run
both `score` and `rank` and compare Rust's winner to the Go scheduler's actual
selection rather than a manually derived expectation.

For those scoring cases the contract also records the selected Go
`RoutingDecision`'s state, queue, pending, backlog, this-request, health, and
capacity-rate components plus effective throughput. Rust uses the same
component model: this-request cost is prefill plus the requested completion
decode, while TTFT's first decode step is not counted a second time. Every
component and the selected total are compared. The only allowed difference is
the fixture-recorded 1 microsecond produced by Rust's conservative integer
ceiling versus Go's floating-point result rounded to microseconds; any larger
drift fails the replay.
