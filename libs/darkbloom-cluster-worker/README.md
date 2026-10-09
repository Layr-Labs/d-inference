# Darkbloom native cluster worker

This separate package builds the experimental resident rank worker and a
two-rank transport check. Its macOS 26.2 deployment minimum is what makes the
pinned MLX compile the real JACCL backend (RDMA over Thunderbolt); below 26.2
`mlx-swift` compiles a stub. The provider and the shared
[`darkbloom-cluster`](../darkbloom-cluster/README.md) modules keep macOS 14, and
no submodule pin changes.

| Product | What it is |
|---|---|
| `darkbloom-cluster-worker` | One rank of a two-Mac resident session. Launched by `darkbloom cluster worker-owner`, never by hand in serving. |
| `darkbloom-cluster-collective-check` | Both ranks run it with the same arguments. It initializes the strict JACCL backend and verifies reductions and point-to-point transfers byte for byte. No model, no weights. |
| `darkbloom-cluster-stage-check` | One Mac, one rank, the real artifact, no collective. Runs the verified loader for that rank's layer range, releases it, and reports memory before, loaded and after. |
| `darkbloom-cluster-reference` | One Mac, both stages, the real artifact, no collective. Runs a request through stage 0 and stage 1 in one process and writes a reference report. |
| `darkbloom-cluster-pair-check` | No MLX. Writes a request, runs it on rank 0 (this Mac) and rank 1 (the second Mac over SSH), and compares a pair report with a reference report. |

`Sources/DarkbloomClusterWorker`: `WorkerMain.swift` is the entry point.
`Startup/` parses startup and bootstrap arguments; `Capabilities/` serves
`--describe-runtime` metadata; `Execution/` holds `WorkerRuntime`,
`WorkerCoordinator` and `NativeWorkerRuntime`; `Transport/` is bounded pipe IO.

## Build

Build the matching Metal kernels from the checked-out MLX sources, then build a
product with that file and its hash:

```sh
bash scripts/fetch-metallib.sh /absolute/path/to/cluster-metal
shasum -a 256 /absolute/path/to/cluster-metal/mlx.metallib

bash libs/darkbloom-cluster-worker/build-native-worker.sh \
  "$PWD/libs/darkbloom-cluster-worker" \
  darkbloom-cluster-worker \
  /absolute/path/to/cluster-metal/mlx.metallib \
  EXPECTED_METALLIB_SHA256
```

The script builds with explicit Swift and C++ 26.2 targets, then refuses the
result unless the binary contains the JACCL group implementation and its Mach-O
minimum is exactly macOS 26.2. It copies the verified metallib beside the binary
and prints the binary path. `DARKBLOOM_CLUSTER_WORKER_BUILD_JOBS` sets the job
count (default 2). See the [provider build procedure](../../docs/developer/build.md)
for toolchain and submodule setup.

## Checks

```sh
# Metadata command and input helpers; no MLX, no model.
bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh

# Worker orchestration against a fake runtime (needs the 26.2 targets).
swift build --package-path libs/darkbloom-cluster-worker --build-tests \
  --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2
swift test --package-path libs/darkbloom-cluster-worker --skip-build \
  --triple arm64-apple-macosx26.2

# The startup refusals of a built worker (qualification switches, generation
# mode); no model, no GPU, a second or two.
bash libs/darkbloom-cluster-worker/Tests/StartupChecks/run.sh /ABS/darkbloom-cluster-worker
```

## Generation modes

How the two ranks divide one request is declared to both workers at launch
with `--generation-mode` and is part of the load agreement they compare before
either stage is read. Absent, the worker runs the pipeline exactly as before.

| `--generation-mode` | What runs |
|---|---|
| `pipeline_v1` (default) | Every frame passes through rank 0 and then rank 1 |
| `pipeline_compact_decode_v1` | The same pipeline; a decode step's messages travel as four transfers instead of eleven |
| `phase_split_v1` | The prompt is prefilled as a pipeline. After the first selected token rank 0 hands its request state to rank 1, which holds every layer and decodes alone, and relays tokens to rank 0 in batches |

The mode must be one the registered model's own row lists; the three dense
models (9B, 27B, Bonsai 2 27B) list all three, and `--describe-runtime` reports them as
`supportedGenerationModes` (omitted when a runtime runs the pipeline only, so
such a record keeps the bytes it always had). An unknown mode is refused at
startup; it never falls back to the pipeline. A phase-split rank 1 loads both
stages, so it takes longer to become ready and its `ready` capacity includes
the hand-off's own allowance.

Two switches exist for qualification only and cannot take effect in a worker
that was not started with `--qualification-switches yes`:
`DARKBLOOM_CLUSTER_TRANSPORT=local-socket-test` (both ranks on one Mac over a
loopback socket: correctness only, never a pair timing) and
`DARKBLOOM_CLUSTER_QUALIFICATION_FAULT` (a fault a recording rank commits
during a hand-off). Without the flag a worker that finds either in its
environment stops at startup and names it. The pair driver passes the flag
only when it sets one of them; an installed owner never does.
`DARKBLOOM_CLUSTER_GENERATION_MODE`, the name a launcher used before the
argument existed, is refused always.

## Per-Mac stage check

Run on each Mac, for each rank it may serve, before any two-Mac attempt. The
arithmetic environment is the worker's and must be set exactly:

```sh
env DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
  darkbloom-cluster-stage-check --model-dir /ABS/MODEL --rank 1 --stage-cut 4
```

The registered model is the one whose pinned `config.json` the directory
holds, and the cut must be one of that model's cuts (4, 8, 12 or 16 for the
9B; 4 through 60 in steps of 4 for the 27B and for Bonsai 2 27B).

A model's arithmetic contract can require more than those three variables.
Ternary Bonsai 2 27B is a Prism Hadamard pack: its ranks also need
`DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC=1` and
`DARKBLOOM_BONSAI_F16_CONSTANT_CACHE=1`, with `MLX_QUANTIZED_CONSTANT_CACHE`
unset. A rank started without them is refused before anything is read. The
pair driver and the solo driver add a request model's own variables themselves.
It passes the same admission and host resource gates as the worker, hashes the
artifact, materializes only that rank's stage, then releases it. The JSON
receipt carries the verified aggregate, the storage commitment (equal on both
ranks and both Macs for one cut), loaded bytes, load time, and active and cached
bytes after release. Exit status is 0 only if the model object was released.
`--hold-seconds N` keeps the loaded stage resident for N seconds first, so a
second load can be tried against it.
It refuses to run with a cluster transport environment set. It shows nothing
about membership, transport or generation.

## Comparing a pair with one Mac

A two-Mac run is judged against a single Mac running the same request through
the same two stages. Three steps: write a request, run it on one Mac, run it on
the pair; then compare. Reports name roles (`single host`, `rank 0 local`,
`rank 1 remote`) and the chip in each role; no report contains an address, a
host name or a user name. A report file is never overwritten.

```sh
# 1. The request: fixed text through the artifact's own tokenizer, in its chat
#    format with thinking disabled. --prompt-tokens repeats and cuts the text's
#    tokens to an exact prompt length. Stop IDs default to none, so the run
#    always produces --output-count tokens. The request names the registered
#    model whose tokenizer made it; --model-id chooses for token-ID prompts.
darkbloom-cluster-pair-check request --model-dir /ABS/MODEL --user-text-file prompt.txt \
  --prompt-tokens 4096 --chunk-size 512 --output-count 64 --output request.json

# 2. Single-host reference, on either Mac, at the cut the pair will use.
env DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
  darkbloom-cluster-reference --model-dir /ABS/MODEL --request request.json \
  --stage-cut 4 --report reference-cut4.json

# 3. The pair. Run on the Mac that is rank 0; it starts rank 1 over SSH.
darkbloom-cluster-pair-check run --request request.json --stage-cut 4 --report pair-cut4.json \
  --remote-ssh SSH_DESTINATION \
  --local-worker /ABS/darkbloom-cluster-worker --remote-worker /ABS/darkbloom-cluster-worker \
  --local-model-dir /ABS/MODEL --remote-model-dir /ABS/MODEL \
  --local-rdma-device rdma_enX --remote-rdma-device rdma_enY \
  --coordinator RANK0_LINK_IPV4:PORT

# 4. Degree of agreement.
darkbloom-cluster-pair-check compare --reference reference-cut4.json --candidate pair-cut4.json
```

**Reference.** It admits each rank as its worker would, loads both stages
through the verified loader with the worker's allocator policy, and for every
frame runs stage 0, copies the residual into a fresh allocation (the pair moves
those bytes over the link), runs stage 1 and applies the pair's greedy
selection. The report holds the selected token IDs; for every token the four
largest logits of its row and the row's digest; the complete final row; and
every state entry's digest. It also records load and frame times, memory
before, loaded and after release, and the decoded output. Exit status is 0
only if both stage models were released. Each run also drives the pair's own
per-rank capture and checks that the two records it produces, the ones a
recording worker writes, read back and join into the same evidence.

**Pair run.** Before launching anything the driver hashes the worker and the
`mlx.metallib` beside it on both Macs and refuses to continue unless both pairs
are identical; it also refuses if a worker from that path is already running.
It refuses a worker that does not contain JACCL's progress guard: on the stock
JACCL a rank whose peer dies spins in the completion poll and nothing inside
the process ends it. The guard's limit, `JACCL_PROGRESS_TIMEOUT_MS`, is set for
both ranks from `--progress-timeout-ms` (default 60000; a rank waiting in a
receive also waits out its peer's compute, so raise it for a prompt chunk that
needs longer). `--allow-unguarded-jaccl yes` lifts the refusal.
It asks each worker to describe its runtime for that Mac's `config.json` and
`manifest.json` and requires equal answers. It then writes the same device
matrix on both sides (under `--local-scratch-dir` / `--remote-scratch-dir`,
default `/tmp`), sets `JACCL_RANK`, `JACCL_IBV_DEVICES`, `JACCL_COORDINATOR`,
the three arithmetic variables and `JACCL_PROGRESS_TIMEOUT_MS`, and starts
rank 0, then rank 1. Each worker's lifetime is a deadline on its own
Mac's clock, computed there; reservation deadlines are translated to that
clock. The request itself is driven by `ClusterWorkerPair`.

`--preflight-only yes` stops after those inspections: it reports the hashes,
the chips, the selected plan and that no worker is running, and launches
nothing.

By default the workers run with `--evidence-directory`, which makes each rank
write its selected history and state digests, and rank 1 the final row, to a
file the driver collects afterwards. That is the only way to see rank 1's
tokens or any logits: the worker protocol reports tokens from rank 0 alone.
`--evidence none` runs the serving path and yields rank 0's tokens only.

`--mode pipeline|pipeline-compact|phase-split` declares the generation mode
to both workers (the driver refuses a mode the workers do not describe).
`--repetitions N` (serving path) runs N requests in one loaded session and
times each on the driver's clock; the first is the warm-up.
`--stop-after-tokens N` makes the owner stop like a client that hangs up.
`--transport local-socket-test` with `--remote-command-prefix` runs both ranks
on this Mac, and `--fault RANK:…` asks one recording rank for a hand-off fault;
both are qualification inputs and make the driver start the workers with
`--qualification-switches yes`. `darkbloom-cluster-pair-check solo` times one
Mac alone on the same driver clock through `darkbloom-cluster-reference
--serve yes`, and `darkbloom-cluster-reference --handoff in-process` moves
stage 0's state through the hand-off's own serialize, verify and adopt code
inside one process.

The driver never signals a worker. After a completed request it sends
`shutdown`, waits for `shutdownComplete` and for the process to exit. On any
failure it cancels the request, closes each worker's input and waits for the
process to end by itself: a worker that loses its input releases its model and
exits, and one blocked in a native call ends at its lifetime. A failed run can
therefore take up to `--lifetime-seconds` (default 240, at most 300); use a
short lifetime for first attempts. Interrupting the driver (Ctrl-C) or closing
its terminal does not reach the workers: they ignore both, see their input end
and exit the same way. The report gives each rank's exit status,
the number of worker processes left on each Mac and each Mac's wired memory
before the launch and after the last exit. For rank 1 the status is the one
`ssh` relays; 255 means the SSH connection itself failed. Each side's run
directory is removed at the end, once no worker is left there, unless
`--keep-run-files yes`. The driver itself, like the reference, ends at a hard
deadline kept by a thread; a worker's own last resort is the same.

The second Mac needs the worker and `mlx.metallib` in one directory (the driver
hashes both) and the artifact. Copy `mlx-swift-lm_MLXLMCommon.bundle` and
`mlx-swift_Cmlx.bundle` from the build output beside them as well: on the build
Mac the reference runs from a directory holding only the binary and
`mlx.metallib`, but there a missing bundle can still be found in the build
directory, so that run does not show they are unnecessary elsewhere.

**Verdict.** `compare` prints whether the request identities match, how many
tokens agree and the first index that differs, the largest absolute difference
in the final row, how many state entries differ, and one of:

| Verdict | Meaning |
|---|---|
| `exact` | Tokens, frame count, committed frontier, the final row's bytes and every recorded state entry are equal |
| `tokensEqualLogitsDiffer` | Every token is equal; the final row or a state entry is not bit-identical |
| `divergedAtNearTie` | At the first different token, the reference's own gap between its choice and the candidate's is within `--near-tie-ulps` (default 4) units in the last place of its top logit |
| `diverged` | The first different token was not a near tie, or cannot be shown to be one |
| `incomparable` | Not the same request, or equal tokens with no final row to settle the first two verdicts |

Two different chips are not expected to be bit-identical, so anything but
`diverged` and `incomparable` can be an acceptable result; read the numbers.
`--allow-cut-difference yes` compares two runs of one request at different
cuts, and `--allow-schedule-difference yes` a lookahead pair run with a serial
one or with the reference, which is always serial. `--require exact,tokensEqualLogitsDiffer` turns the verdict into an exit
status. `--model-dir` adds the decoded text around a divergence.

Tests (no model, no second Mac; two copies of a fake worker stand in for the
two Macs and rank 1 is reached through `/bin/sh -c` in place of `ssh`):

```sh
# Without SwiftPM or MLX, in about half a minute.
bash libs/darkbloom-cluster-worker/Tests/QualificationChecks/run.sh

# The same tests in the package, after the test build under Checks above.
swift test --package-path libs/darkbloom-cluster-worker --skip-build \
  --triple arm64-apple-macosx26.2 --filter DarkbloomClusterQualificationTests
```

## Two-rank transport check

Each Mac needs RDMA enabled (`rdma_ctl status`), an active port
(`ibv_devinfo`), and **an IPv4 address on the Thunderbolt interface itself**.
A port that only belongs to the Thunderbolt Bridge publishes no IPv4-mapped GID
and JACCL refuses it. Both Macs read the same device matrix: row *i*, column *j*
is the device rank *i* uses to reach rank *j*.

```sh
# matrix.json on both Macs, for example: [[null,"rdma_en7"],["rdma_en6",null]]

# Rank 0 listens on the coordinator address; start it first.
JACCL_RANK=0 JACCL_IBV_DEVICES=/abs/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  darkbloom-cluster-collective-check --mode raw --max-mib 64

JACCL_RANK=1 JACCL_IBV_DEVICES=/abs/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  darkbloom-cluster-collective-check --mode raw --max-mib 64
```

`--mode raw` calls the MLX C API directly; `--mode wrapper` drives the same
transport through the runtime's `Collective` type. Each rank prints one JSON
report and exits 0 only when both ranks saw zero mismatches. A pass shows the
strict backend initialized and carried the bytes correctly; it does not by
itself show which device carried them. Record that separately, for example by
comparing the payload volume with the interface byte counters.

A blocked native collective cannot be interrupted from inside the process, so
both products end on a fixed deadline (`--deadline-seconds` for the check, the
load deadline for the worker).

### How a worker ends

A worker's owner does not signal it while it is within its own deadlines. The
owner's fence is the end of the worker's command stream, and the worker ends
itself:

| What happens | What the worker does | Exit status |
|---|---|---|
| `shutdown` while idle | releases the model, publishes `shutdownComplete` | 0 |
| command stream closes, or `cancel` | cancels its request, releases the model | 1 |
| peer stops answering inside a collective | fails at the collective progress limit (`JACCL_PROGRESS_TIMEOUT_MS`), then releases the model | 1 |
| not ready by `--startup-deadline-uptime-nanoseconds` | ends at once without releasing anything | 123 |
| still running at `--deadline-uptime-nanoseconds` | ends at once without releasing anything | 124 |

The last two are last resorts for a process that cannot be interrupted from
inside: a rank that waits for a peer that never connects, or one that spins in a
collective. `--startup-deadline-uptime-nanoseconds` is optional and must lie
within the lifetime; an owner that passes it may treat that moment as final for
a worker that never became ready. The owner sends SIGTERM only after the
applicable deadline plus a margin, and SIGKILL only to a process that ignored
both.

## Limits

- The worker accepts the registered Qwen3.5 9B and Qwen3.8 27B artifacts,
  greedy text, one request at a time. The 9B has run across two Macs. The 27B
  has passed admission, per-rank stage loads and the single-Mac reference on
  both chips; it has not yet completed a two-Mac run (see
  [handoff/QWEN27B-PAIR.md](../../handoff/QWEN27B-PAIR.md)).
- Ternary Bonsai 2 27B (a Prism Hadamard pack; adapter
  `qwen35-prism-hadamard-layer-stage`) is the third dense model. It has run
  across two Macs at cut 24 in all three generation modes with every token
  equal to the single-Mac reference, and a rank ended mid-decode left
  nothing behind. Its stream and state are float32. Both Macs must hold the
  artifact: it has no pinned content inventory, so a stage cannot be received
  from the peer. The provider's installed path has no pair-serving row or
  rank environment for it yet.
- The host gate admits on free pages plus part of the file cache: three
  quarters of the file-backed memory that is both above the kernel's own
  file-cache minimum and short of the point where half of the cache is
  active, at most 32 GiB, and only while memory pressure is normal. Anonymous
  memory is never counted. A load or a request stops counting cache once the
  Mac has compressed more than 512 MiB or swapped out more than 64 MiB since
  its first check, and then stops unless free pages alone are enough. This is
  proven on two Macs with 128 and 256 GB only. It does not protect a Mac whose
  cache is mapped by another program (the load is stopped after about half a
  GiB has been compressed, each time it is tried), two loads started together
  can both be stopped part-way, and a Mac with 32 or 48 GB is mostly refused.
  A refusal names the requirement, the free pages and the cache counted, and
  says when waiting for more cache cannot help. The stage check and the
  reference print the gate's record per load and per request; a load that
  fails part-way prints one record with what it still held after release. See
  [handoff/DESIGN-resource-gate-v3.md](../../handoff/DESIGN-resource-gate-v3.md).
- The owner-authenticated JACCL bootstrap (`--bootstrap-socket-path`,
  `--bootstrap-owner-pid`, `--bootstrap-deadline-uptime-nanoseconds`) is parsed
  but refused: the pinned mlx-c does not carry the bootstrap bridge. Without
  those flags the worker uses the direct native bootstrap, where JACCL opens its
  own coordinator socket. The installed provider therefore starts the worker
  without them and reports `nativeBootstrap: directNative` in `cluster status`.
- `--prefill-schedule` accepts `serial_v1` and `one_chunk_lookahead_v1`;
  omission means serial. `--describe-runtime` advertises the supported
  schedules; capability metadata does not report readiness or available memory.
- `--evidence-directory` is for qualification only. It selects the recording
  entry of the same resident runtime; the installed owner never passes it.
  `--uptime-nanoseconds` prints the clock worker deadlines are expressed in.
- Neither a worker build nor a pipe fixture qualifies remote ownership, model
  correctness, external TTFT, or production serving.
