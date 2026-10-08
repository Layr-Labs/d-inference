# Independent CPU audit — Qwen output precision

The audit verified all 78 logical executions, 130 rank reports/logit files,
130 archived experiment sources, every per-run bundle manifest and its actual
files, declared model/input/policy identities, and identical peer outputs.
All 52 matched-policy comparisons, 54 policy departures and six native
regressions reproduce the driver’s recorded metrics and decisions.

`independent-cpu-audit.json` records 1,553 evidence hashes, per-comparison
results and the audit script identity. `independent-cpu-audit.py` is the exact
CPU-only script used. No native process, GPU work or source edit inside Git
was performed by this audit.

## Matched-policy BF16 results

Each cell is strict numerical passes / six cases; every passing BF16 case is
also exactly equal. The unchanged gate is maximum absolute error <0.001,
worst-row relative RMS <0.0001, and matching argmax.

| Output policies widened | FFN TP | Full TP |
|---|---:|---:|
| Neither | 0/6 | 0/6 |
| Attention/GDN only | 0/6 | 0/6 |
| FFN down projection only | 5/6 | 0/6 |
| Attention/GDN and FFN down projection | 6/6 | 5/6 |

With both outputs widened, all 96 compared argmax rows agree. The full-TP miss
is `qwen27-heads`, seed 31, prompt 96/chunk 32: only output row 0 differs, with
max absolute error 0.009765625 and relative RMS 0.00547284136705869. The other
seven teacher-controlled decode rows are exact. This residual is not explained
by the ordinary-versus-CBv2 head-shape diagnostic: both sides here use the same
CBv2 output-narrowing schedule, so further isolation is required.

With only the FFN output widened, FFN-TP misses `qwen27-heads`, seed 101,
prompt 129/chunk 32, at output rows 2–6; worst relative RMS is
0.0033956404064672497. Full TP misses all six cases, with worst relative RMS
0.019693092339771748. Its tiny seed 7 prompt 37 case changes argmax at row 3:
the matched-policy solo chooses 310 and full TP chooses 412. Overall full-TP
argmax agreement is 47/48 for this policy.

The four Float32 matched-policy comparisons pass unchanged strict bounds;
worst relative RMS is below 7.92e-7. Native and both-widened Float32 outputs
are byte-exact within each corresponding solo/FFN/full execution mode.

## Departure from native solo behavior

All six solo cases differ numerically from native under each nonnative policy.
Each policy agrees with native argmax in 46/48 rows. The two changes are the same
tiny seed 7 prompt 37 case at rows 3 and 4: native chooses 412/118, while attention-only,
FFN-only and both-widened solo executions choose 310/79. This is direct evidence
that better same-policy TP agreement is not proof of equivalent model behavior.

All six previous-native regressions are exact, covering tiny/qwen27-heads
BF16 seed 7 prompt 65 in solo, FFN and full modes. Shared model/config/layout,
prompt/history and execution identities agree across the old/new records.

## Metric and qualification limits

Swift Float JSON values use short decimal representations. The audit first
reproduces the driver’s calculations on those parsed decimals, then reconstructs
the native IEEE754 Float32/BF16 values and recalculates the errors. Trailing
digits differ slightly; no pass, exactness or argmax conclusion changes.

Solo reports retain `throughputMeasurementValid:true` for isolated forward
timers whose logit capture occurs afterward. Loopback reports mark it false.
All 78 run manifests set `hardware_throughput_candidate:false`, and the matrix
receipt sets `performance_qualification:false`. These are bounded synthetic,
teacher-controlled local tests, without production scheduler, paged-backend,
RDMA, real-artifact quality or cluster-throughput qualification. The experiment
source manifest is not a full dependency-build or weight-content attestation.

An initial auditor assertion incorrectly expected the solo timing flags to
match loopback flags. Source inspection established the intended distinction;
no native execution failed and no experimental data or acceptance gate changed.
