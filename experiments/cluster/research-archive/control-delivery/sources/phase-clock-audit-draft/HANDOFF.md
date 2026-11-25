# Local phase sidecar CPU audit

Frozen before first phase-candidate access. Root had already begun a native
phase invocation before this freeze. This agent read no candidate run output,
launched no native/model/GPU/SSH operation and ran only fabricated CPU tests.

The four core Python files use stdlib and one hash-pinned scalar action helper.
They do not import numerical/model-loading helpers. `phase_fixture.py` creates
fabricated metadata, deliberately including opaque placeholders that would not
pass the separate numerical oracle. A passing phase audit is supplementary;
run the existing numerical and executable/archive/runtime provenance audits too.

API:

```python
validate_one(stdout_path, trace_path, role)  # solo, rank0 or rank1
validate_solo(stdout_path, trace_path)
validate_ranks([stdout0, stdout1], [trace0, trace1])
```

CLI:

```sh
python3 phase_clock_audit.py solo STDOUT TRACE
python3 phase_clock_audit.py ranks STDOUT0 TRACE0 STDOUT1 TRACE1
```

Inputs are bounded to 16 MiB per two-record stdout and 512 KiB per sidecar.
Duplicate keys, deep JSON, nonfinite constants/exponents, extra fields, Boolean
or fractional integer metadata, explicit null for absent frame fields and
injected-clock labels are rejected. Input and helper/source bytes are checked
before and after replay. Production capture's fixed default capacity is 512.

The base metadata check derives the full recorded request/history fingerprint
from the exported 8192 token IDs, exact 16 chunks of 512, and request UUID. Rank
agreements and their domain fingerprints bind this identity across both files.
It does not independently bind these token IDs to the original raw prompt file;
that remains the numerical/provenance audit's scope.

The sidecar requires exactly 41 solo events or 204/235 rank events. Rank events
also correspond one-to-one with the separately source-derived scalar actions
and their prepared/pending/completed counters. It verifies UInt64 arithmetic,
nondecreasing local clocks, exact frontiers and same-process enclosure/order
against the original primary clock. Solo's close marker follows the original
close timestamp; rank0's close marker precedes its timestamp. Rank1 has no
primary clock, and no timestamps are aligned or subtracted across processes.

Intervals are copied CPU metadata. Solo chunk and stage0 preparation spans
include synchronization and observer overhead; stage1 consumption includes
final finite selection. Named collective intervals include validation and any
scheduler/wait delay, so they are not isolated wire or GPU timings. All selected
intervals are disjoint within a local trace; gaps remain unclassified. There is
no cross-rank total, concurrency, GPU-overlap, physical-transfer or causal-speedup
claim. Publication and outer model release/cache clear follow request tracing.

Reproduce the 72 fabricated CPU tests:

```sh
python3 -m unittest discover -s . -p test_phase_clock_audit.py -v
```

The bounded source review by `pipeline_stage_plan` found no schema/order issue;
its finite-exponent parser concern was already addressed before the passing
run. Python 3.9 syntax was checked separately. Swift compilation and real phase
execution remain root-owned; neither is evidence produced by this helper.
