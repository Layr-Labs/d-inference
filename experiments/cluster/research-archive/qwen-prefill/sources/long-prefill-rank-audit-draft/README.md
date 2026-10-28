# Prospective 8K v4 rank CPU audit

The production API is:

```python
validate([rank0_stdout_path, rank1_stdout_path], baseline_stdout_path,
         prompt_path, expected_prompt_sha256, epoch, policy)
```

The command line takes those seven positional inputs in the same order, with
rank0 and rank1 as separate arguments. `policy` is `serial_v1` or
`prompt_lookahead_one_v1`. The explicit epoch must be 32 lowercase hex characters.
Neither epoch nor raw-prompt pin is inferred from candidate reports.

Production validation pins the completed 8K reference stdout and its separate
CPU qualification receipt. It checks dependencies, input files and helper files
before and after replay. Input JSON is bounded, rejects duplicate object keys and
nonfinite values, and preserves an integer spelling of negative zero. All outer
and nested evidence schemas are closed; typed integer checks reject floats and
booleans. Canonical wire bytes are required because the tested native sender
constructs them canonically; this is narrower than the pure decoder's admission
of semantically valid whitespace.

The oracle independently derives a fresh request/history, v4 agreement,
16 producer and 16 consumer commits, actual envelope/token byte hashes, domain
fingerprints, phase-specific ACK byte expectations, and 204/235 action timelines.
Source inventories conserve all 927 canonical text tensors across 463/464 owners;
inert inventories and per-stage bytes are checked separately. Final state contains
36 entries per rank and 72 entries in the disjoint global union.

The full reference BF16 row is independently reconstructed from its exported
Float values, including signed zero, and supplies the finite first-index argmax
and tie count. Candidate logit and numerical-state values are not exported.
Their metadata/digests must equal the frozen reference. The eight Int32 offset
digests can be reconstructed; the other 64 state digests and all boundary payload
digests remain opaque. ACK bytes are independently derived expectations, not
exported observations. The test `source_bound_opaque_payload_limit` deliberately
demonstrates that coherent cross-rank fabricated payload digests cannot be
disproved without payload bytes.

Source phase placement determines the clock semantics: readiness precedes the
rank0 origin clock; fresh context admission/creation and scalar trace recording
are included; final consumed ACK and token validation precede stop; post-stop
release, final captures and close follow stop. UInt64 arithmetic and the exact
Double rate formula are checked. This qualifies no stable throughput, physical
link, concurrency, representative workload or cluster speedup. Allocator samples
are cumulative MLX observations, not RSS or process peaks.

Prospective tests use fabricated records, generated prompt IDs, frozen header
inventories and synthetic opaque digests. Both policies have separately assembled
fixture timelines. The complete-file API test temporarily patches the expected
baseline hash to a fabricated file, then proves the normal fixed baseline pin
rejects that file. It is file-handling coverage, not native qualification.
No new rank candidate was read while writing or running these tests. At freeze,
root reported that no native rank candidate existed. No model payload, SSH,
transport, native inference, build or GPU operation was performed by this audit.

The existing reference and pair helpers remain unchanged. `rank_dependencies.py`
binds their pins and the frozen flow, transport, codec and entry sources. The
rank oracle does not reproduce Foundation configuration floating-number
serialization; its plan construction identities are bound to the already-frozen
Foundation control. Actual loading, source descriptor hashes, release/retirement,
arithmetic-environment application and native phase observations still require
separate executable/archive/runtime provenance.

Independent source-only review by `pipeline_stage_plan` found no concrete
schema/order/count blocker. It checked callback frontiers, optional rank-specific
fields, exact hash domains and the Float64 rate recipe against frozen source.
