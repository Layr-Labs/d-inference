# Candidate metadata checks

Proposed public location: `experiments/cluster/inference/Tests/LayerStageCandidates`.
From a checkout with the production candidate enumerator integrated:

```sh
bash experiments/cluster/inference/Tests/LayerStageCandidates/run.sh
```

The script compiles the actual production candidate, plan, metadata, bounded-input
and JSON-scanner files using the macOS Swift toolchain. It does not invoke SwiftPM,
link MLX, initialize a GPU, read checkpoints or use the network. Foundation,
CoreFoundation and CryptoKit are supplied by the platform. Temporary compiler
output is removed on exit. An optional source-directory argument supports an
isolated reviewed checkout; no private location is embedded in the script.

The only test substitutes are `ProbeError` and the CryptoKit `sha256(Data)` helper,
copied from their otherwise unrelated production files. All planner/admission
and integer parsing code remains production code. The existing PlanCheck's small
configuration is nested inside its function, so this harness supplies its own
public synthetic configuration and explicit canonical suffix tables without
changing production APIs or deriving expected names from `moduleInventory`.

Positive cases prove global/local parameter round trips, complete disjoint state
ownership, embedding/norm/head responsibilities, unchanged widths/dtype/RoPE,
quantization override reindexing, deterministic identities under name permutation,
and inactive component exclusions. Three constructor forms use 12 layers with
cuts 4 and 8; a 10-layer case admits 4+6, preserving the final partial interval.
Negative cases exercise incomplete/duplicate/unknown names, wrong layer policies,
quantization aliases, active MTP, unsupported geometry and input bounds. Candidate
tests do not use `output_gate_type`. A separate exact copy of the gate-admission
fixture checks absent/`swish`/`silu` declarations and invalid values with direct-text
and nested-wrapper synthetic inputs, preserving source spelling and identity.
It requires the reviewed experimental metadata guard; it changes no decoder.

Three success JSON records report the candidate cases, direct-text gate cases,
then nested-wrapper gate cases. Failure writes an error to stderr and exits
nonzero; earlier records can remain and do not establish overall success.
The fixture contains parameter names, not tensor
payloads: it does not prove descriptor shapes/dtypes/triplets, checkpoint bytes,
native load budgets, model arithmetic, legal device assignments or compute costs.
Those remain separate loader/runtime qualification responsibilities.

Draft status: source-only; root will compile and execute after review. Expected
success is five ownership cases and 21 rejection cases, followed by two gate
records with three accepted and 15 rejected cases each. Not yet executed here.
