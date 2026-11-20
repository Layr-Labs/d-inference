# Balanced 9B prefill candidate

This package prepares cut4 and cut16 with the same retained ordinary generation
runtime, one-chunk lookahead, diagnostic P8192/C512/O128 prompt, empty stops and
MTP off. No model, remote command, installed configuration change or new native
build was performed. Root owns deployment, resource admission and physical runs.
Independent review is pending; this is a reviewable launch candidate, not measured
speedup or current capacity qualification. Optimized solo is a separate follow-up.

The native worker is `009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b`
from `resident-lookahead128-bundle-20260915`. It is exactly the worker used in the
prior cut4 lookahead correctness and corrected-pump timing cohorts. The private
recording wrapper selects `one_chunk_lookahead_v1` once and calls the ordinary
shared generation driver through its recording SPI. It does not use the MTP
probe. The product installed runtime/defaults are not involved. Native admission
already permits cuts4/8/12/16, preserves the300-second/16-request bounds and uses
`disableFreedBufferCache`. The same owner-provided authenticated mesh bootstrap,
shared planner/loading/state/retirement, request allowances and live guards run.

The coherent fixed owner controls come from
`owner-retirement-controls-build-20260915/bundle-mtp`; that folder's historical
name does not select MTP. Its configured9B entry admits4/8/12/16 and launches the
configured worker. All four dylibs are from that fixed bundle, including the
reviewed late-shutdown service correction. Do not mix legacy owner libraries.
The normal controller SHA is
`13311eeac86a019a7c187249fbe7393471e9e158821f5eaa8d5637f392851a74`.

The timing controller is the exact five previously qualified timing sources,
relinked against those same four modules. Its new SHA is
`c4483d8ce5e86f73986cdd7fb1a26e0053428883275b2de3850ea5f89bb88b1c`.
One Foundation-only compile passed in0.658seconds with14 input pins unchanged;
no native compiler or new actual-child fixture ran. The linked dylib identities
and exact copied timing sources are retained under `timing/`. Compiler is released.

## Prospective identity and correctness

`metadata/` reuses the retained native candidate catalog and independent tensor
metadata/hash recipe. The only recipe changes select16 and admit4/8/12/16.
Cut4 reproduces its historical expected identities. Cut16 reproduces the entire
`load` object of both retained Sept14 actual stage-constructor receipts. Six
source files are byte-identical and the storage commitment DTO/assembly sections
are identical between that constructor and009a; `source-equivalence.json` pins
this proof. Modern aligned-file IO accounting does not change the commitment.
No new installed-model offset scan, loaded-byte attestation or numerical result
is inferred from that provenance.

| Item | cut4 | cut16 |
|---|---:|---:|
| Selected tensors rank0/rank1 |118 /809|463 /464|
| Selected tensor bytes rank0 |1,058,851,136|2,519,016,704|
| Selected tensor bytes rank1 |3,979,190,464|2,519,024,896|
| Final state components rank0/rank1 |9 /63|36 /36|

Both partitions conserve all927 canonical tensors,5,038,041,600 selected bytes,
and the same72-component final state. Cut16 Plan is
`2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293`, storage
`a3a852726b2cce3420a13eb345c46903deafc07ce2771ce678e1a0675b7e341d`.
Arithmetic is unchanged
`0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74`.
Each correctness case has a prospective fully bound `expected-agreement.json`.

The raw prompt SHA is
`ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.
Correctness retains request6426b803-8b80-40ba-8944-b0f4b403a3cf for the fixed
independent full-model reference. Each case has its own fresh epoch and child
lifetime. Do not reuse an attempted case/epoch or existing evidence directory.

`cut16-audit` is a small derivative of the frozen lookahead comparator. It keeps
the original full-reference bytes/pin and cut4 reference Plan as provenance of the
unpartitioned full model; the candidate Plan/stages/construction/ranges are cut16.
It requires128 selected IDs,143 frames, frontier8319, the entire248320-value final
BF16 row, and the ordered72-component state union. Lookahead evidence remains
explicit: rank0 prepared15/max1, rank1 prepared0/max0, no pending consumed frame or
decode prefetch. Only three comparator runtime files change; the math, framing,
reference/token/state checks otherwise remain. Twenty-six invented CPU checks
pass, including cross-rank state movement, old-cut relabeling and swapped Plan
provenance. Six separate configuration/ownership checks pass. The old cut4 audit
is unchanged. Intermediate per-token rows/frontiers remain unavailable and are
not claimed verified.

## Root deployment and launch

`deployment.json` maps the exact native three-file closure and11 case files per
rank: fixed owner+four dylibs, four sampler files, matrix and rank owner.json.
Create fresh mode0700 directories at
`/Users/developer/DarkbloomDev/qwen9b-balanced-prefill-20260915`, its `native` directory,
and the selected case directory plus `evidence`. Parent directories for nested
resource paths must exist. Apply each listed file's mode and verify the complete
selected tree against the manifest on BOTH Macs before launch. Owner.json must be
beside its configured owner executable. Every outer config and embedded ready
record is compact single-line JSON plus exactly one LF. This prevents the earlier
27B pretty-printed outer-record refusal.

The parent reads the already authorized development SSH trust paths; the known
hosts hash is89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed.
No private key/password bytes were accessed during preparation. Both owner children
acquire `/Users/developer/.darkbloom/cluster-device/native-device.lease`; the parent does
not hold that native gate. Confirm idle actual processes, empty canonical journals,
reachable peers, AC/zero swap and native free-memory admission before each run.
This parent never recovers or clears a journal.

After root's source/deployed-tree review, run correctness first:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen9b-balanced-prefill-candidate-20260915
/usr/bin/python3 -B check_source.py
/usr/bin/python3 -B run_case.py --case cut16-correctness
```

The case's `physical-1` must be absent. `run_case.py` changes only the globals of
the exact copied parent: base/remote/output/controller paths. The parent retains
315-second owned controller timeout, actual group reaping,420-second two-host
process/journal observation and the600-second alias lease. Postflight occurs
before alias release, including failures. A lost observation or sticky journal
fails the run. The native lifetime/request limits stay300/120seconds; no cross-
host uptime subtraction is added. Exact parent tests were retained, not rerun.

Root then retrieves both bounded sidecars from that case's remote
`evidence/6426b803-8b80-40ba-8944-b0f4b403a3cf.json`, keeping separate rank files,
raw remote hashes/identities and fresh process/journal checks. Existing bounded
sidecar collection primitives can be reused with only this path/request binding.
No retrieval is performed by this package preparation. Build the local packet:

```sh
/usr/bin/python3 -B prepare_comparison.py --case cut16-correctness \
  --rank0 cases/cut16-correctness/physical-1/returned/rank0-evidence.json \
  --rank1 cases/cut16-correctness/physical-1/returned/rank1-evidence.json \
  --output cases/cut16-correctness/physical-1/comparison-packet.json
```

It prints the packet SHA. Pass that exact printed value to:

```sh
/usr/bin/python3 -B cut16-audit/audit_generation.py \
  --packet cases/cut16-correctness/physical-1/comparison-packet.json \
  --packet-sha256 PRINTED_SHA256 \
  --output cases/cut16-correctness/physical-1/comparison.json
```

This comparator reads the original pinned full-reference output at
`full-generation-reference-physical-20260915/returned/native/worker-0.stdout`,
SHA748b2d11346b3097435f83db53296c4873c3e42a261493614cbfe896883faaa3.
Root separately verifies actual native cleanup, authenticated owner release ACKs,
all resource samples, process absence, empty journals and restored alias. Parent
exit0/actual token output alone is not numerical correctness.

Once cut16 correctness is qualified, run each fresh timing case with the same
`run_case.py --case cut4-timing` or `--case cut16-timing`. Each loads once, executes
one excluded warmup plus three measured fresh requests and explicitly releases
all request state between them. Each request verifies the128 predeclared IDs from
the matched prior reference. The timing controller samples request-start to first
committed token on one local monotonic clock, includes owner transport/forward,
and excludes model load/reserve. It is not external HTTP TTFT. Keep raw first-run
and all measured durations, resource samples and cleanup receipts. Do not include
warmup in the median or relabel the private capture path as production throughput.
Compare case order and thermal/free-memory conditions explicitly; a reverse order
repeat needs new epochs/directories. This package does not auto-run either case.

## Memory and follow-up limits

Cut16 moves1,460,165,568 selected weight bytes onto the24GB rank. Its logical final
state is162,054,160 bytes per rank versus40,513,540/283,594,780 at cut4. These are
logical geometry values, not actual allocator/free-memory predictions. The native
request allowance conservatively charges full-model state to each rank and derives
rank-local fusion plus diagnostic/lookahead allowances before admission. Actual
ready capacities and live allocation bounds remain authoritative. The6GiB free
floor, resource policies and deadlines are unchanged; refusal is a valid result.

The old441.68TPS solo result had one requested output, so it is not the matched
O128 optimized solo baseline. The existing registered full-generation request API
accepts an already loaded model and creates/retire fresh request state, but its
current CLI loads/releases the model once per invocation and records correctness
capture. A small resident wrapper over that existing API, with1+3 fresh requests,
same P/C/O/raw prompt/arithmetic/cache policy and source-qualified optimized solo
kernels, is the next implementation. It requires its own native build/qualification;
no fake runnable solo configuration or unsupported CLI is supplied here. This
remaining comparison does not block measuring cut4 versus cut16 correctly.
