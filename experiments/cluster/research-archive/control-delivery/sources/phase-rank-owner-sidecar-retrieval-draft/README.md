# Four-sidecar rank-owner retrieval

Private source/CPU adapter,2026-09-14. Root alone runs actual SSH. The source
freeze precedes author access to any candidate stdout or sidecar; native rank
execution completed while preparation was in progress.

```sh
python3 retrieve_rank_owner_sidecars.py \
  --run /absolute/completed/rank-owner/run \
  --launcher-receipt-sha256 EXPLICIT_COMPLETED_RECEIPT_SHA256 \
  --output /absolute/new/retrieval-directory
```

Admission requires the exact passed `remote_qwen_long_prefill_rank_owner_launcher`
namespace, both tracing flags, successful/reaped distinct original local SSH
clients, both complete ready/report records, peer request/agreement equality,
rank/source/environment correlation, raw prompt/hosts/config pins, and exact
source-bound loopback stderr. A failed parent or retained source/cleanup failure
has no exception. Both complete configurations include the two distinct fixed
sidecar options. The ten-file rank archive remains unchanged.

Layout comes from the pinned frozen rank `long_rank_paths.paths()` constructor:
one shared `run/bundle`, plus ordered `run/rank-0` and `run/rank-1`. The frozen
client calls this constructor, staging passes its shared bundle and each rank
directory, and the unchanged worker resolves each `@rank` leaf relative to
that rank's configuration. The adapter pins the archived entry, configuration
and path constructor. Its fixture executes only the pinned pure path functions
and uses the frozen configuration function; it rejects the solo
`run/native/bundle` layout even if both saved configurations agree with it.

Reads occur in this fixed order:

1. `run/rank-0/phase-trace.json`
2. `run/rank-0/owner-trace.json`
3. `run/rank-1/phase-trace.json`
4. `run/rank-1/owner-trace.json`

All four must pass. Each result retains its exact raw file, SSH framing bytes,
fixed reader payload, SHA/size/mode observations and request correlation under
`rank-N/phase/` or `rank-N/owner/`. A later failure preserves earlier files and
partial SSH bytes, stops further reads, and records primary versus cleanup
errors separately with the rank and sidecar name. The output directory must be
new; local files use exclusive mode0600 creation.

Both remote payloads, the phase/owner response decoder, SSH helper and byte-I/O
helper are copied byte-identically from corrected solo-owner reader v2. The
owner payload retains its previously reviewed fixed leaf-only difference from
the phase payload. Each read uses the unchanged no-follow descriptor traversal,
regular-file/current-owner/mode0600/single-link admission,512KiB cap and stable
fstat checks. The inherited metadata namespace is
`qwen_prefill_phase_sidecar_read`; exact path and trace kind distinguish each
file. There are no remote writes/deletions; reads may affect access times.

Each SSH read has its own20-second deadline and at most2-second local cleanup
wait. Local reader clients are distinct from original launcher clients and
remote native/supervisor PIDs. No remote waitpid or process-scan proof is added.

All traces must match the full recorded-request fingerprint, registered long
profile, production DispatchTime clock and their rank-specific role. Owner
traces additionally bind frame7, offset3584, count512 and frontier4096, their
separate closed kind/qualification flags and exactly eight events. Event values,
ordering, clock arithmetic, phase containment, numerics, power and cross-process
clock alignment are not audited. The independent semantic and numerical
auditors remain separate. Source/model/resource provenance is not comprehensively
replayed; existing passed launcher evidence keeps its own scope.

Nineteen prospective CPU/fake tests pass with subprocess/socket creation blocked.
They cover both policies, exact rank ownership and configuration, actual
constructor-derived layout, source pins, namespace/PASS/client/record/peer
rejection, all four failure positions, local evidence drift, retained bytes,
strict role/owner-envelope correlation and unchanged shared-helper hashes.
Python3.9 syntax checks cover11files. These tests are not native or SSH execution
proof. Previous readers, their results, and the solo v1 layout-failure evidence
remain untouched.
