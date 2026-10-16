# Nemotron Super qualification runner and benchmark

`NemotronSuperRunner` serves one unpublished Nemotron Super owner on 127.0.0.1
through the provider's real local HTTP stack, with isolated state, until
SIGINT/SIGTERM. `bench_super.py` measures it over HTTP; `memory_calibration.py`
([memory_calibration.md](memory_calibration.md)) compares measured memory peaks
with the reservations it holds. Synthetic-fixture results validate the tooling
only; they are not model speed, memory or quality evidence.

## Where it lives and why

The runner is an executable target of the qualification harness template
([templates/Provider.Package.swift](templates/Provider.Package.swift)) only.
Its sources are under `provider-swift/Tests/NemotronSuperRunner/`; the shipping
`provider-swift/Package.swift` declares no such target, so nothing in the
provider binary can reach it, and no production callsite installs the image
hook. This was chosen over an env-gated test entry because a long-lived server
needs its own process (clean signal handling, a measurable footprint without a
test runner, a release build) and it adds no file to `ProviderCore`. It uses
`@testable import ProviderCore`/`MLXVLM`, so a release build must pass
`-Xswiftc -enable-testing`.

| Mode | Load path | Admission |
|---|---|---|
| `--checkpoint DIR` | `NemotronSuperLocalLoad.load`: pinned config/index/shard identity, `NemotronSuperInstallation.requiredLoadBytes` quote, pending LOAD claim, fenced staging, `NemotronSuperLocalBridgeBuilder.make`, LOAD finish | the process `GlobalKVCacheBudget` with the provider's default cap and activation reserve |
| `--synthetic` | the same steps in the same order on the tiny fixture (the transaction pins the real identity, so it cannot stage a fixture) | same |

Isolation: the state directory must be new or empty; `HOME`, `TMPDIR`,
`DARKBLOOM_STATE_FILE` and `DARKBLOOM_LOADED_MODELS_FILE` point inside it;
credential-shaped environment variables are removed (names are logged). The
runner creates no provider config, coordinator client, discovery record or
registry entry. Both listeners bind 127.0.0.1 and require a per-run bearer
token written to `<state>/auth-token`. The engine sees only `--engine-env`
entries as its runtime-policy environment.

CPU-only client checks (SSE timing math, abort accounting, parsing, PNG
generator; no runner or GPU):

```sh
python3 -B -I -m unittest discover -s scripts/nemotron-qualification -p test_super_runner_client.py
```

## Build

Use the qualification harness (see [README.md](README.md)). Validation can use a
debug build; performance numbers require release.

```sh
nice -n 10 swift build --package-path "$HARNESS" --product NemotronSuperRunner \
  --force-resolved-versions -j 6
nice -n 10 swift build --package-path "$HARNESS" -c release --product NemotronSuperRunner \
  --force-resolved-versions -j 6 -Xswiftc -enable-testing
cp "$METALLIB" "$HARNESS/.build/out/Products/Release/mlx.metallib"
```

`$METALLIB` is the source-matched library built from the pinned nested MLX. MLX
loads `mlx.metallib` from the executable's directory.

## Run

```sh
RUNNER=$HARNESS/.build/out/Products/Release/NemotronSuperRunner
$RUNNER --state-dir /new/dir --checkpoint /path/to/nemotron-super-vl-nvfp4-78327dcf
$RUNNER --state-dir /new/dir --synthetic --template /path/to/chat_template.jinja
```

Run GPU work through the exclusive lane. The scripts below can launch the runner
themselves (`--launch-runner`), which keeps the lane held only while measuring.

| Option | Default | Meaning |
|---|---|---|
| `--checkpoint DIR` / `--synthetic` | required, one of | load mode |
| `--template FILE` | `<checkpoint>/chat_template.jinja` | pinned template; required with `--synthetic` |
| `--preflight` | off | with `--checkpoint`: check identity, template, config, inventory and shard files without reading shards or touching the GPU; writes `<state>/runner-preflight.json` and exits |
| `--port`, `--diagnostics-port` | 0 (ephemeral) | 127.0.0.1 listeners |
| `--max-context` | 16384 | builder maximum; prompt plus output must fit |
| `--default-max-tokens` | 512 | when a request omits `max_tokens` |
| `--kv-capacity-gib` | 4 | bridge KV capacity, also the minimum KV in the LOAD claim (at least 1) |
| `--backend-allowance-gib` | 2 | added to the LOAD quote; an unmeasured runner default |
| `--kv-bytes-per-token` | from config | full-attention layers x 2 x KV heads x head_dim x 2 (8192 for the pinned config); an override may only raise it |
| `--cap-fraction` | provider default (0.90) | may only lower the cap; an inherited `DARKBLOOM_MEM_CAP_FRACTION` is removed |
| `--sample-interval-ms` | 50 | ledger/memory sampling; use 5 for calibration, 50-100 for speed |
| `--drain-timeout-seconds` | 600 | bound on waiting for in-flight work after a shutdown signal |
| `--verify-parallelism` | 4 | concurrent shard SHA-256 checks (whole-shard reads) |
| `--engine-env KEY=VALUE` | none | runtime-policy entries, for plain/speculative A/B |

Shard verification streams all 88 shards before staging, which also fills the
file cache; `load.phase.end` events time `verify_shards`, `tokenizer` and
`native_load` separately. A cold-cache load needs a fresh boot or an emptied
file cache, and the receipt cannot tell which you had.

## Files and routes

| Path | Content |
|---|---|
| `<state>/runner-ready.json` | written after both listeners bind: URLs, pid, executable, build configuration, identity, settings, load seconds and phases |
| `<state>/runner-events.jsonl` | `runner.start`, `load.begin`, `load.phase.*`, `load.quote`, `load.end` (with the load memory window), `serve.ready`, `charge.opened`/`charge.retired`, `shutdown.*`, `retirement`, `runner.exit` |
| `GET /runner/memory` | fresh sample: process footprint (current, kernel interval max, lifetime max), MLX active/cache/peak, ledger (charged, materialized, remaining, cap, activation reserve, owners), charge rows and sums by kind, `unattributed_bytes` (ledger charge outside the rows, e.g. engine owners), maxima since the last reset including `sampled_max_request_charges_held` (request kinds held at the same time), HTTP/bridge activity |
| `POST /runner/peaks/reset` | returns the closing window, then resets the kernel interval footprint, MLX peak and sampled maxima |
| `POST /runner/ballast` | `{"bytes": N}` holds a real ledger reservation that shrinks the remainder (near-limit probes); released at drain |
| `GET /runner/status` | ready-file content plus live activity |

Charge kinds: `load` (pending LOAD claim), `media_ingress` and `media` (the
image binding's `-ingress`/`-media` reservations), `kv` (bridge request
reservations, which include each request's fixed prefill workspace), `ballast`.
Request bytes come from the budget's read-only `reservationBytesSnapshot()` and
the hook from `NemotronSuperLocalLoad.localImageHTTP(templateBytes:)`
(`RunnerChargeRows.swift`, `RunnerCheckpointLoad.swift`). The owner serves one
request at a time: a concurrent request gets 429 before any response starts.

Speculation is an engine-environment A/B: with `--checkpoint`, pass
`--engine-env DARKBLOOM_NEMOTRON_SUPER_MTP=1` and optionally
`DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` (`1`…`3`) and
`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION` (`rectangular` or `serial`). The load
transaction reads exactly these entries (not the inherited process
environment), adds the head's LOAD supplement and records the resolved setting
as `speculation` in the ready file's identity (`null` for the plain arm). The
speculating hook is text-only: image requests get 400. `--synthetic` has no MTP
head and refuses the opt-in.

## Shutdown

The first SIGINT/SIGTERM cancels a load in progress, or closes admission (new
requests get 503), waits up to `--drain-timeout-seconds` for in-flight HTTP and
bridge work, stops both listeners, releases ballast, then retires the owner
(`closeAfterDrain`). If the signal arrives during load, the load is cancelled
and nothing is served. Exit 0 means the owner retired and the process ledger
holds no charge; 2 is a failed load that retired cleanly; 3 is retained
ownership or an outstanding charge; 4 is a clean retirement after a listener
failure or a drain that hit its timeout. A second signal exits at once and logs
`runner.forced_exit` with unverified retirement.

## Benchmark

```sh
python3 -I bench_super.py run --out plain.json --launch-runner "$RUNNER" \
  --runner-arg=--checkpoint --runner-arg="$MODEL" --runner-arg=--sample-interval-ms --runner-arg=100 \
  --source provider="$PROVIDER" --source sdk="$SDK" --source mlx="$MLX" --model-dir "$MODEL"
python3 -I bench_super.py run --out spec.json --arm speculative --launch-runner "$RUNNER" \
  --runner-arg=--engine-env --runner-arg=KEY=VALUE ...   # or --extra-body '{"field": true}'
python3 -I bench_super.py compare plain.json spec.json
```

Defaults: contexts `short=128,medium=2048,long=15360` prompt tokens (fitted
from the first request plus up to `--calibration-steps` one-token requests), images `512x512,1024x1024,2048x1536`,
concurrency `1,2,4,8` with 2 requests per client, `max_tokens` 128, one warmup,
three repetitions, seed 1234, `temperature` 0, `top_p` 1, `enable_thinking`
false (`--thinking on|default` for the reasoning channel). `compare` refuses receipts with different
workload settings, model identity or runner build configuration.

| Metric | Definition |
|---|---|
| cold load | runner `load.end` seconds and phases; process start to ready file |
| first TTFT | first request of each context at its uncalibrated initial length (first-use cost for that shape); only the first workload runs directly after load |
| cold TTFT | new leading nonce on a warmed process; no prompt prefix shared |
| warm TTFT | byte-identical repeat; `cached_prompt_tokens` shows any reuse (none expected: this owner has no prefix store) |
| prefill tok/s | prompt tokens / TTFT (end-to-end lower bound) |
| decode tok/s | (completion tokens - 1) / (last delta - first delta) |
| e2e tok/s | completion tokens / request time |
| concurrency | p50/p90/p99 latency and TTFT of successful requests, aggregate completion tokens / wall time, statuses (the owner admits one request at a time, so 429 rejections are reported, not hidden) |

The receipt records hardware, OS, thermal and memory pressure, git HEAD plus a
hash of each checkout's diff and untracked files, the runner executable SHA-256
and build configuration, model identity and local revision, settings, and every
raw sample with its memory window. A debug runner adds a warning.
