# M5 SSD KV-Cache 4-Hour Stress Soak — Runbook

Drives the encrypted SSD prefix cache on the **M5 Max bench box** (NOT prod) for
a fixed duration under a prompt mix designed to exercise the store → reload →
evict paths, then checks the run against pass/fail criteria.

> **Scope / safety.** This is a **test/stress run on an authorized bench box**
> (`gaj@m5-max-128gb-1.tail618116.ts.net`). It stops the production `darkbloom`
> daemon for the duration and **restores it afterward**. It does **not** touch
> prod infrastructure, EigenCloud, or any signed-deployment config. The build
> used is an **unsigned** local build that runs the cache with an **ephemeral
> in-memory KEK** (`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`) — cache files do
> not survive a restart and this flag must never be set on a signed build.

---

## 0. Why the special flags

The provider gates the cache behind a Secure-Enclave-wrapped KEK. An **unsigned**
build (which is all we can produce on the bench box without the production
`SLDQ2GJ6TL` Apple cert) has no `keychain-access-groups` entitlement, so the SE
key is unreachable (`OSStatus -34018`) and the cache **silently disables**.

`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1` is a test-only escape hatch
(commit `334e67c1`) that lets the unsigned build run the cache logic end-to-end
with a process-random in-memory KEK.

The model under test is **`gemma-4-26b`**, which routes to the
**checkpoint tier** (sliding-window). Two non-obvious consequences:

| Knob | Default for Gemma | Why we override |
|------|-------------------|-----------------|
| `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS` | **16384** (Gemma is a "proven" family) | At the default, no prompt under 16k tokens ever reaches SSD. We set **0** so every checkpoint persists and the disk store/reload/evict paths are actually exercised. |
| `DARKBLOOM_PREFIX_CACHE_MAX_GB` | physical/8 (≈16 GB) | We set **4 GB** to keep the RAM tier small so warm entries spill and must reload-from-SSD (the decrypt path). |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | min(10 GB, free/2) | We set **4 GB** so sustained diverse traffic fills the budget and triggers benefit-per-byte **eviction** within the 4 h window. |

Checkpoint boundaries for the in-window ladder start at **256 tokens**
(`[256, 512, 1024, 2048, 4096, 8192]`). The driver's `SHARED_PREFIX` is several
hundred tokens, so shared-prefix requests cross ≥1 boundary and produce
persistable checkpoints.

---

## 1. Prerequisites (one-time, on the M5)

```bash
ssh -i ~/.ssh/mtp_bench -o IdentitiesOnly=yes gaj@m5-max-128gb-1.tail618116.ts.net

# Repo up to date with the escape-hatch commit (334e67c1).
cd ~/projects/darkbloom/d-inference
git fetch origin
git checkout feat/ssd-kv-cache
git pull --ff-only origin feat/ssd-kv-cache
git submodule update --init --recursive    # mlx-swift-lm gitlink moves with our fixes

# Build ONLY the darkbloom product (the kv-se-harness target is stale and fails).
cd provider-swift
swift build -c release --product darkbloom

# Stage mlx.metallib next to the release binary (serve needs it; same as CI).
# The release fetch needs a python wheel the box's Python 3.9 can't get, so copy
# the metallib from the debug test bundle that's already built:
cp .build/arm64-apple-macosx/debug/DarkbloomProviderPackageTests.xctest/Contents/MacOS/mlx.metallib \
   .build/release/mlx.metallib 2>/dev/null \
 || cp "$(/usr/bin/find .build -name mlx.metallib -print -quit)" .build/release/mlx.metallib

ls -lh .build/release/darkbloom .build/release/mlx.metallib
.build/release/darkbloom --version
```

Confirm the model is present (no download needed — it's in the HF cache from
prior runs). `gemma-4-26b` is the serveable alias for
`mlx-community/gemma-4-26b-a4b-it-8bit` (arch `gemma4`, ~31 GB est. memory):

```bash
.build/release/darkbloom models list --all | grep -i gemma-4-26b
# expect: "mlx-community/gemma-4-26b-a4b-it-8bit  gemma4  8bit ... 26.0 GB" and the "gemma-4-26b" alias
```

---

## 2. Stop the production daemon (authorized, for this test only)

The bench box normally runs a **signed** prod daemon connected to
`wss://api.darkbloom.dev/ws/provider`. Stop it so it doesn't compete for the GPU
or the model, and so our unsigned build is the only thing serving.

```bash
# Identify how prod is running (launchd vs nohup).
launchctl list | grep -i darkbloom || true
pgrep -fl darkbloom

# If launchd-managed (typical), unload it (note the label to restore later):
launchctl list | grep -i darkbloom    # capture the LABEL (e.g. io.darkbloom.provider)
# launchctl bootout gui/$(id -u)/<LABEL>     # or: launchctl unload <plist path>

# If it's a plain process, stop it gracefully:
.build/release/darkbloom stop 2>/dev/null || true
pkill -f 'darkbloom .*start' 2>/dev/null || true

# Verify nothing darkbloom is serving:
pgrep -fl darkbloom    # should be empty
```

> **Record exactly how it was running** (launchd label + plist path, or the
> command line) — §6 restores it.

---

## 3. Clean baseline

```bash
KV_DIR="$HOME/Library/Caches/darkbloom/kv"
du -sh "$KV_DIR" 2>/dev/null || echo "no kv dir yet"
# Start from a clean cache so disk-growth numbers are attributable to this run.
rm -rf "$KV_DIR"
mkdir -p ~/soak && cd ~/soak
```

Copy the two driver scripts up (from your laptop, or `git pull` already brought
them in under `scripts/`):

```bash
# they live in the repo:
cp ~/projects/darkbloom/d-inference/scripts/load_soak.py ~/soak/
cp ~/projects/darkbloom/d-inference/scripts/cache_soak_monitor.sh ~/soak/
chmod +x ~/soak/cache_soak_monitor.sh
```

---

## 4. Pre-flight smoke test (≈5 min — DO THIS BEFORE THE 4 H RUN)

Validates the whole rig: server boots, cache initializes with the ephemeral KEK,
files land on disk, markers fire, no crash. Use a tiny disk budget so eviction
shows up fast.

**Terminal A — server (tmux/screen so it survives disconnect):**

```bash
cd ~/projects/darkbloom/d-inference/provider-swift
export DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1
export DARKBLOOM_PREFIX_CACHE=1
export DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS=0
export DARKBLOOM_PREFIX_CACHE_MAX_GB=4
export DARKBLOOM_PREFIX_CACHE_DISK_GB=1          # tiny on purpose for the smoke test
.build/release/darkbloom start --local --no-auth \
    --model gemma-4-26b --port 8000 2>&1 | tee ~/soak/smoke_server.log
```

Wait for `Standalone server listening on 127.0.0.1:8000`. Confirm the cache came
up with the ephemeral KEK (NOT disabled):

```bash
grep -E 'encrypted prefix cache active|EPHEMERAL in-memory KEK|prefix cache disabled' ~/soak/smoke_server.log
# WANT: "...active..." and the EPHEMERAL warning. MUST NOT see "disabled".
```

**Terminal B — monitor:**

```bash
cd ~/soak
./cache_soak_monitor.sh --kv-dir "$HOME/Library/Caches/darkbloom/kv" \
    --proc darkbloom --interval 15 \
    --out-csv smoke_samples.csv --events-log smoke_events.log --raw-log smoke_provider.log
```

**Terminal C — load (3 min):**

```bash
cd ~/soak
# Small pool (8) + tiny disk budget (set DISK_GB=1 on the server) so SSD
# promotion, disk-eviction, AND decrypt-reload all fire within 3 minutes.
python3 load_soak.py --base-url http://127.0.0.1:8000/v1 \
    --model gemma-4-26b --duration-minutes 3 \
    --concurrency 4 --max-tokens 64 \
    --prefix-pool 8 --prefix-repeat 6 --unique-fraction 0.15 \
    --out smoke_client.csv
```

**Smoke pass criteria** (all must hold before the 4 h run):
- `smoke_client.csv`: `cum_err` is 0 (or only transient startup errors), tokens flowing.
- `smoke_samples.csv`: `disk_kb` grows above 0; `store` > 0 and `sweep`/`evict` > 0.
- Raw provider log shows SSD activity: `wrote N chunks` (store), and ideally a
  `disk sweep`/`evicted for global budget` (SSD eviction). Decrypt-reload is not
  logged on success — a sustained re-hit with 0 `decrypt_fail` is the signal.
- `smoke_events.log`: **no** `decrypt_fail`, **no** `DISABLED`.
- Server log: no crash / fatalError / Swift trap.

Stop the smoke server (Ctrl-C in Terminal A), monitor + load exit on their own.
Clear the cache again before the real run: `rm -rf "$HOME/Library/Caches/darkbloom/kv"`.

---

## 5. The 4-hour soak

> **Confirm with the user before starting** — this monopolizes the bench box and
> keeps prod down for 4 h.

Use a **tmux** session (`tmux new -s soak`) so everything survives SSH drops, OR
`nohup … &`. tmux is preferred — you can re-attach and watch.

**Pane 1 — server:**

```bash
cd ~/projects/darkbloom/d-inference/provider-swift
export DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1
export DARKBLOOM_PREFIX_CACHE=1
export DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS=0
export DARKBLOOM_PREFIX_CACHE_MAX_GB=4
export DARKBLOOM_PREFIX_CACHE_DISK_GB=4
.build/release/darkbloom start --local --no-auth \
    --model gemma-4-26b --port 8000 2>&1 | tee ~/soak/soak_server.log
```

**Pane 2 — monitor (auto-stops at 4 h + a 5-min tail):**

```bash
cd ~/soak
./cache_soak_monitor.sh --kv-dir "$HOME/Library/Caches/darkbloom/kv" \
    --proc darkbloom --interval 30 --duration-minutes 245 \
    --out-csv soak_samples.csv --events-log soak_events.log --raw-log soak_provider.log
```

**Pane 3 — load (exactly 4 h):**

```bash
cd ~/soak
python3 load_soak.py --base-url http://127.0.0.1:8000/v1 \
    --model gemma-4-26b --duration-minutes 240 \
    --concurrency 4 --max-tokens 128 \
    --prefix-pool 48 --prefix-repeat 6 --unique-fraction 0.15 \
    --report-every-seconds 60 --out soak_client.csv
```

**Why pool mode (not the simple shared/diverse split).** SSD persistence is a
**2nd-use promotion**: a checkpoint flushes to SSD only when a prefix already in
RAM is *hit again* (`PrefixCacheManager.lookup`, the `Task.detached
persistDigest` branch). A single shared prefix therefore promotes **once** and a
diverse one-off **never** — so the simple split exercises store + RAM eviction
but leaves the SSD **disk-eviction** and **decrypt-on-reload** paths cold.

Pool mode uses **48 distinct long prefixes**, each reused across requests:
- 1st use → RAM store; 2nd use → **SSD promotion** (write-back, ~115 MB/file for
  this model's 512-token checkpoint).
- 48 × ~115 MB ≫ `DISK_GB=4` → **SSD disk-eviction** (`enforceDiskBudget`).
- 48 prefixes vs a RAM budget that holds ~35 → re-hitting an evicted prefix is a
  RAM miss + index hit → **`loadFromSSD` decrypt-reload**.
- `--unique-fraction 0.15` adds one-off churn so pool members keep getting
  evicted and reloaded.

Adjust `--concurrency` up if the GPU is underused (watch `tok_per_s`).

When the load driver exits, Ctrl-C the server in Pane 1.

---

## 6. Restore production (MANDATORY teardown)

```bash
# Stop the soak server if still up.
pkill -f 'darkbloom .*start --local' 2>/dev/null || true

# Restore prod exactly as it was (from the note you took in §2):
#  - launchd:  launchctl bootstrap gui/$(id -u) <plist path>   (or `launchctl load <plist>`)
#  - process:  the original prod start command

# Verify prod reconnected:
pgrep -fl darkbloom
# Tail its log / confirm it re-registers with the coordinator.
```

> Do **not** leave `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` exported in any shell
> that launches the prod daemon. The ephemeral flag is harmless on a signed
> build (the SE path succeeds first, so the catch block never runs) but must not
> be relied on. Start prod from a clean shell.

---

## 7. Pass / fail criteria (4 h run)

| # | Criterion | Source | Pass |
|---|-----------|--------|------|
| 1 | No crash / Swift trap / fatalError | `soak_server.log` | clean |
| 2 | No client errors beyond transient | `soak_client.csv` `cum_err` | ≈0, no sustained band |
| 3 | Disk footprint bounded by budget | `soak_samples.csv` `disk_kb` | stays ≲ `DISK_GB` (4 GB ≈ 4.2 M KB), plateaus rather than growing unbounded. **This plateau is the primary SSD-eviction proof.** |
| 4 | SSD eviction actually fires | `sweep`/`evict` cols + raw log | `global disk budget exceeded … enforcing` + `signaled owned model … to free` once disk fills. (The legacy per-model `enforceDiskBudget` is silent — the **GlobalDiskAccountant** is the active authority and logs every enforcement.) |
| 4b | RAM eviction fires | `ram_evict` col | > 0 (LRU under `MAX_GB`) |
| 5 | **No decryption failures** | `soak_events.log` / `decrypt_fail` col | **0** |
| 6 | No MB-1 / hash-mismatch drops mid-run | `mb1_drop`, `hash_mismatch` cols | 0 (a few at startup from reconcile are acceptable; document) |
| 7 | Memory bounded | `soak_samples.csv` `rss_kb` | plateaus; no monotonic leak over 4 h |
| 8 | Cache never silently disables | `disabled` col + server log | 0 occurrences mid-run |
| 9 | Hit benefit visible | `soak_client.csv` TTFB | shared-prefix windows show lower `total_p50` than the diverse-heavy early window (best-effort signal; hits aren't logged explicitly) |
| 10 | No thermal collapse | `soak_samples.csv` `cpu_speed_limit` | stays 100 (or recovers; sustained <100 = throttling, note it) |

---

## 8. Collect artifacts

```bash
cd ~/soak
tar czf soak_artifacts_$(/bin/date +%Y%m%d_%H%M).tar.gz \
    soak_client.csv soak_samples.csv soak_events.log soak_provider.log soak_server.log
```

Pull to the analysis box with `scp -i ~/.ssh/mtp_bench gaj@m5-…:~/soak/soak_artifacts_*.tar.gz .`
and run the post-run analysis (pass/fail report against §7).

---

## 9. Observability notes / gotchas

- Cache hit/miss is **not** exposed over HTTP (X-Timing carries no cache field).
  The client CSV measures only TTFB/total/tokens/errors. Actual cache behavior
  comes from the provider's unified-logging markers, which `cache_soak_monitor.sh`
  captures via `log stream --predicate 'subsystem == "dev.darkbloom.provider"'`.
- **Hit/miss IS logged** (since the stats-logger change): the checkpoint-tier
  scheduler emits `prefix cache stats: lookups=.. hits=.. (ram=.. ssd=..)
  misses=.. hitRate=NN.N% stores=.. ssdFlushes=.. diskEvictions=..
  ssdReadErrors=..` every 120 s (override/disable with
  `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS`; `0` disables). The monitor
  parses the latest `hitRate=` into the `hit_rate` CSV column. Note this covers
  the **checkpoint tier** (Gemma); pure-attention `.engine` models have no
  hit/miss counters and log nothing here. `misses` counts only lookups that hit
  neither RAM nor SSD (genuine cold/unique prompts) — so for the pool workload
  the steady-state hit rate reflects pool reuse, with the ~15% unique-prompt
  injection as the miss floor.
- Successful SSD **reads/decrypts are not logged** (only failures are). So a
  zero `decrypt_fail` count + sustained disk reuse is the success signal, not an
  explicit "hit" line.
- Per-file **store** markers (`wrote N chunks to …`) are `debug` level — the
  monitor uses `--level debug`, no sudo needed.
- The monitor reads only the bytes appended to `--raw-log` since the previous
  tick, so marker counts are per-interval deltas (the CSV columns).
- If `store`/disk stays 0 during the smoke test, the most likely cause is
  `MIN_PERSIST_TOKENS` not being 0 (Gemma default 16384) — re-check the exports.
