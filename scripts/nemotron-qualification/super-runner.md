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
| `--checkpoint DIR` | `NemotronSuperLocalLoad.load`: pinned config/index/shard identity, `NemotronSuperInstallation.requiredLoadBytes` quote, pending LOAD claim, fenced staging, `NemotronSuperLocalBridgeBuilder.make`, LOAD finish | the process `GlobalKVCacheBudget` with the provider's default cap and the activation reserve the provider holds for a lone Super slot (its measured floor) |
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
loads `mlx.metallib` from the executable's directory. Like the managed load, the runner pins MLX's memory limit and buffer-cache cap
with `MLXMemoryGuard` before loading (physical memory less 6 GB, and 8 GiB of
cache unless `DARKBLOOM_MLX_MEMORY_RESERVE_GB` or `DARKBLOOM_MLX_CACHE_LIMIT_GB`
says otherwise); `runner.start` and the ready file report them as
`mlx_limits`. Without the cap, MLX keeps freed buffers up to its default
limit, and the shared budget, which counts cached buffers as used, refuses
requests the provider would admit.

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
| `--max-context` | 262144 | the managed slot's context, also the most the builder accepts; prompt plus output must fit |
| `--default-max-tokens` | 512 | when a request omits `max_tokens` |
| `--kv-capacity-gib` | 4; with speculation 12 or the managed slot's admission for N requests, the depth table and `--max-context` (`NemotronSuperServingPolicy.admissionKVBytes`, about 15.7 for N = 8 at 262144), when larger; plain 1 + 3 x N with `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT=N` > 1 | bridge KV capacity, also the minimum KV in the LOAD claim unless `--managed-load-claim` (at least 1). Every request's fixed bytes are carved from it; the ready file's identity `kv_grant` reports `requests`, `minimum_grant_bytes` (for that many requests), `fixed_request_bytes`, `serving_concurrency`, and the per-token rates each request's reservation adds for its prompt plus `max_tokens` (`kv_bytes_per_token`, of which `auxiliary_bytes_per_token` is the speculating assistant's history), and a too-small grant fails the load with `kv_grant_refused` (the same fields and `suggested_kv_capacity_gib`, `null` when no grant is provable) in `load.failed` and on stderr |
| `--managed-load-claim` | off | the LOAD claim holds the managed slot's KV headroom instead of the whole grant: every configured request's fixed bytes, 2 GiB and the default prefix bank (`NemotronSuperServingPolicy.loadPlan`), recorded as `admission_kv_bytes` in `load.quote`. A large grant then loads as it would in the provider; as there, the claim also holds the prefill lane and the bank once, and hands the installation's share to live usage once it is resident |
| `--backend-allowance-gib` | 2 | added to the LOAD quote; an unmeasured runner default |
| `--kv-bytes-per-token` | from config | full-attention layers x 2 x KV heads x head_dim x 2 (8192 for the pinned config); an override may only raise it |
| `--cap-fraction` | provider default (0.90) | may only lower the cap; an inherited `DARKBLOOM_MEM_CAP_FRACTION` is removed |
| `--sample-interval-ms` | 50 | ledger/memory sampling; use 5 for calibration, 50-100 for speed |
| `--drain-timeout-seconds` | 600 | bound on waiting for in-flight work after a shutdown signal |
| `--verify-parallelism` | 4 | concurrent shard SHA-256 checks (whole-shard reads) |
| `--engine-env KEY=VALUE` | none | runtime-policy entries, for plain/speculative A/B |
| `--emulate-physical-gib N` | off | behave as a dedicated Mac with N GiB (at most this machine's): the process budget's total is N GiB and its OS-available memory N GiB minus the runner's footprint (never above what this machine has), `MLXMemoryGuard`'s limits are N GiB's, the managed load gate (scan-time footprint plus activation reserve and minimum KV against available-for-load memory) runs before loading and refuses as the provider would (`emulation.load_gate` event), and the default prefix bank is sized for N GiB; `load.quote` adds the KV grant the provider's re-slice would give (`emulated_production_grant_bytes`) |

`load.quote` reports the installation's payload and staging, the head's
payload and construction allowance and their sequential sum
(`installation_head_bytes`); the transaction's actual LOAD charge, with the
transient overlapping its serving room, is the `charge.opened` row of kind
`load`.

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
| `GET /runner/engine` | cumulative speculation counters (rounds, seed steps, drafted, accepted and emitted tokens, per-position acceptance, depth selections, skips; `null` on the plain owner) and, with `CBV2_STEP_PROFILE=1` in the runner's environment, every step-profiler phase's count, total, p50 and p90 milliseconds |
| `POST /runner/engine/profile/reset` | clears the step profiler's samples (speculation counters stay cumulative) |

Charge kinds: `load` (pending LOAD claim), `media_ingress` and `media` (the
image binding's `-ingress`/`-media` reservations), `kv` (bridge request
reservations: recurrent state, any speculation charge, one decode row and KV),
`prefill_lane` (the owner's one prompt-chunk activation allowance, held from
before the first request until retirement; the checkpoint path charges the
SDK's full-model `prefillActivationBoundBytes` for the configured chunk),
`prefix_bank` (the owner's resident checkpoint bank budget, held like the lane
when prefix caching is on), `mtp_round` (a speculating owner's round work,
verify window, captured-window generations and history copies, held once like
the lane; the ready file's `request_charge.mtp_projected` reports its exact
`owner` bytes beside the serving policy's `policy_owner_bound`), `ballast`.
`sampled_max_request_charges_held` includes the lane and the round, not the
bank.
Request bytes come from the budget's read-only `reservationBytesSnapshot()` and
the hook from `NemotronSuperLocalLoad.localImageHTTP(templateBytes:)`
(`RunnerChargeRows.swift`, `RunnerCheckpointLoad.swift`). The owner serves one
request at a time unless `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT` raises it: a
request beyond that gets 429 before any response starts.

Speculation is an engine-environment A/B: with `--checkpoint`, pass
`--engine-env DARKBLOOM_NEMOTRON_SUPER_MTP=1` and optionally
`DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` (`1`…`3`; `auto`: the engine's marginal
policy picks 0…3 each step from measured acceptance and round cost; or a comma
list such as the managed default `3,2,2,2,1`: the depth for N requests decoding
in the step, the last entry for more; both rectangular only) and
`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION` (`rectangular` or `serial`). The load
transaction reads exactly these entries (not the inherited process
environment), adds the head's LOAD supplement and records the resolved setting
as `speculation` in the ready file's identity (`null` for the plain arm). The
speculating hook serves image requests target-only, without speculation. `--synthetic` has no MTP
head and refuses the opt-in. Concurrency is the same kind of switch:
`--engine-env DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT=N` serves N requests with
row-exact batched decode (`1`…`64`) or, with rectangular speculation, verifies up
to N requests in one captured window per round (`1`…`8`); request N + 1 gets 429.
Prompts prefill in chunks of `DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK` tokens
(default 2048, at most the calibrated limit), one chunk per step beside every
decode or verify row; `DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS`
(`0`…`64`, default 0) adds decode-only steps between chunks while requests
decode. Chunk geometry never depends on concurrency, so outputs match solo
serving. The speculative grant default is the managed slot's admission for N
requests at `--max-context` (`NemotronSuperServingPolicy.admissionKVBytes`,
15.7 GiB for eight at 262,144 tokens), at least 12 GiB; otherwise pass `--kv-capacity-gib` from the ready file's `kv_grant`,
or from `suggested_kv_capacity_gib` after a `kv_grant_refused` load.

KV storage is the same kind of switch: `--engine-env
DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND=paged` stores the attention KV in the
segmented native paged backend. Its pages and recurrent rows are charged by the
engine's process-memory owner (reported in `unattributed_bytes`, not as `kv`
rows) and the owner holds the decode rows as `decode_rows` from load to
retirement. The prefix bank composes with it. The gated
`NemotronSuperPagedLiveTests` (`DARKBLOOM_SUPER_PAGED_LIVE=1` and
`NEMOTRON_SUPER_CHECKPOINT_DIR`, exclusive GPU) stages the pinned checkpoint
once and compares paged against contiguous logits at every 2,048-token chunk
end of a 16,000-token prompt and over 64 decode steps fed the contiguous
choices. Paged prefill must be bitwise equal. Decode reduces differently, so a
third, contiguous arm prefilled in 1,024-token chunks calibrates the trunk's
own sensitivity: paged decode must stay within the larger of 0.1 and twice
that arm's largest relative deviation, with at most the larger of 2 and twice
its greedy disagreements. Every position's deviation is printed.

The gated `NemotronSuperMemoryLiveTests` (`DARKBLOOM_SUPER_MEMORY_LIVE=1` and
`NEMOTRON_SUPER_CHECKPOINT_DIR`, exclusive GPU) is the native memory ledger:
MLX active memory, its peak and the process footprint around the installation
and head (against their quotes), every 2,048-token chunk of one prompt and
plain decode steps on contiguous and paged storage (with each attention row's
storage type, dtype and bytes), the first chunks again with the residual stream
evaluated every 8 and 2 layers (timed; results unchanged), one chunk under the
stage profile's memory recording, and the largest image grid's tower and
projector (against the media activation bound). `DARKBLOOM_SUPER_MEMORY_PROMPT`,
`DARKBLOOM_SUPER_MEMORY_DECODE` and `DARKBLOOM_SUPER_MEMORY_BACKENDS` size it.

Text prefix caching is the same kind of switch: `--engine-env
DARKBLOOM_PREFIX_CACHE_MEMORY=1` gives the owner the SDK's resident
recurrent checkpoint bank (`NemotronSuperLocalPrefixCache`), sized like the
managed slot's: `NemotronSuperServingPolicy.defaultPrefixBankBytes` of
`--kv-capacity-gib` and the machine for the pinned checkpoint (half of what the
grant leaves beside every request's fixed bytes, the prefill lane and one
image, and half of what the memory cap leaves beside the rest of the LOAD
claim, at most a quarter of the grant and 16 GiB, none below 1 GiB; for eight
speculating requests on 256 GiB: 16 GiB at `--kv-capacity-gib 100`, none at
50),
`min(1 GiB, KV grant / 8)` for synthetic weights, or
`DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`. It is carved from the grant
and charged as `prefix_bank` from load to retirement. One long entry holds two
162.3 MiB checkpoints, the prompt's KV and, on the speculating owner, 8 KiB of
assistant history per checkpoint token (0.39-0.44 GB at ~5.9K tokens). Checkpoints sit only at multiples of
the prefill chunk, so a request restores the deepest chunk boundary below its
last prompt token that a previous text request published, and prompts shorter
than one chunk restore nothing. On the speculating owner each checkpoint also
holds the assistant's queued prompt history (8 KiB per token), so a restored
request drafts from the same history as a cold one. An image request reuses
only checkpoints of its own image identity (the same images at the same
positions). `context.prefix_cache` in `GET /runner/status` and `GET /runner/memory`
reports the bank's `adoptions`, `tokens_saved`, `lookup_matches`, `misses`,
`entries`, `evictions` and bytes (`null` without a bank); the HTTP usage's
`cached_tokens` stays 0 on this route. `kv_grant.minimum_grant_bytes` includes
the bank. `bench_super.py` alternates cold and warm requests and each cold one
publishes too, so a one-entry bank evicts the warm body before its repeat: give
long-context warm runs a grant with a default bank or an explicit one, for
example `--engine-env DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES=1073741824`. Each sample
records the bank counters as `prefix_cache_after`.

## Serving policy benchmark

`bench_serving.py` serves the 16 natural prompts of `serving_prompts.json`
(code, chat, math and long-form, four each) greedy at each client count, every
client sending `--requests-per-client` requests back to back, and records per
request TTFT, decode tok/s and the full text, per level the aggregate
completion tok/s and the `GET /runner/engine` speculation delta (acceptance,
emitted tokens per round, depth selections). `--pad-words 1500,6000` repeats
the levels with a nonce-led filler document of that many words before every
prompt (TTFT under load). `compare` checks that every prompt's output is
byte-identical across receipts and levels (a run cut at a smaller `max_tokens`
must be a prefix).

```sh
python3 -I bench_serving.py run --out plain.json --arm plain --launch-runner "$RUNNER" \
  --runner-arg=--checkpoint --runner-arg="$MODEL" \
  --runner-arg=--engine-env --runner-arg=DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT=8 --warmup
python3 -I bench_serving.py run --out d3.json --arm d3 --launch-runner "$RUNNER" \
  --runner-arg=--checkpoint --runner-arg="$MODEL" \
  --runner-arg=--engine-env --runner-arg=DARKBLOOM_NEMOTRON_SUPER_MTP=1 \
  --runner-arg=--engine-env --runner-arg=DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH=3 \
  --runner-arg=--engine-env --runner-arg=DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT=8 --warmup
python3 -I bench_serving.py compare plain.json d3.json
```

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
| warm TTFT | byte-identical repeat; without the prefix bank it prefills cold. With `DARKBLOOM_PREFIX_CACHE_MEMORY=1` it restores the deepest published chunk boundary below its last token; `cached_prompt_tokens` stays 0 on this route, so read `context.prefix_cache.tokens_saved` |
| prefill tok/s | prompt tokens / TTFT (end-to-end lower bound) |
| decode tok/s | (completion tokens - 1) / (last delta - first delta) |
| e2e tok/s | completion tokens / request time |
| concurrency | p50/p90/p99 latency and TTFT of successful requests, aggregate completion tokens / wall time, statuses (the owner admits its configured requests, one by default, so 429 rejections are reported, not hidden) |

The receipt records hardware, OS, thermal and memory pressure, git HEAD plus a
hash of each checkout's diff and untracked files, the runner executable SHA-256
and build configuration, model identity and local revision, settings, and every
raw sample with its memory window. A debug runner adds a warning.
