# Coordinator differential pilot

`scripts/pilot-load.py` provides two complementary isolated test paths:

- `component` runs the real Go handler/registry and Rust Axum runtime with their
  in-process synthetic WebSocket peers. It covers the 1,000-session gate,
  request/chunk pressure, concurrency and slow-consumer behavior, session
  replacement, hedging, and `sent_unknown`.
- `run` launches or targets two loopback coordinators, optionally launches one
  peer command per coordinator, sends the same seeded HTTP trace to each, and
  compares every observed semantic field. A mismatch passes only when a rule in
  `allowed-differences.json` matches it.

The quick component gate is:

```bash
python3 scripts/pilot-load.py component --profile quick
```

The scheduled command repeats the component profile for at least 30 minutes:

```bash
python3 scripts/pilot-load.py component --profile scheduled --duration-seconds 1800
```

For an external differential run, coordinator origins must be loopback HTTP
addresses. Launch mode also requires two distinct local PostgreSQL databases.
Setup commands receive only `PILOT_DATABASE_URL`; coordinator and peer
processes receive scrubbed environments so ambient production credentials
cannot leak into an isolated run.

```bash
python3 scripts/pilot-load.py run \
  --profile quick \
  --go-url http://127.0.0.1:18080 \
  --rust-url http://127.0.0.1:18081 \
  --go-database-url postgresql://pilot_user:pilot_local_only@127.0.0.1:5432/pilot_go \
  --rust-database-url postgresql://pilot_user:pilot_local_only@127.0.0.1:5432/pilot_rust \
  --go-setup-command "./local-go-schema-setup" \
  --rust-setup-command "./local-rust-schema-setup" \
  --go-command "./coordinator-go" \
  --rust-command "./coordinator-rust" \
  --go-peer-command "coordinator-rs/target/release/darkbloom-pilot-peer" \
  --rust-peer-command "coordinator-rs/target/release/darkbloom-pilot-peer" \
  --go-peer-control http://127.0.0.1:18180/control \
  --rust-peer-control http://127.0.0.1:18181/control \
  --go-counter-url http://127.0.0.1:18080/_pilot/counters \
  --rust-counter-url http://127.0.0.1:18081/_pilot/counters
```

Synthetic peer commands receive `PILOT_COORDINATOR_URL`,
`PILOT_PROVIDER_TOKEN`, `PILOT_SEED`, `PILOT_WEBSOCKET_SESSIONS`, both load
multipliers, the JSON concurrency ramp, and slow-consumer settings. Peer
control endpoints accept the deterministic `session_replacement`, `hedge`, and
`sent_unknown` directives. Counter endpoints return `mailbox_used`,
`mailbox_capacity`, `database_pool_used`, and `database_pool_capacity` under
either the root object or `pilot_counters`.

The scheduled profile repeats deterministic load cycles until its configured
duration has elapsed. Every cycle gets unique deterministic request indexes and
idempotency keys. Reports are written atomically as JSON and Markdown below
`artifacts/pilot-load/`. Quick and scheduled profiles require committed measured
baselines. Hardware runs apply absolute budgets by default and enable observed
throughput, latency, prediction-error, and resource regression limits when
passed a profile-matched `--baseline`.

Baselines are generated only from a passing differential report. The command
writes both the baseline and a hash-pinned source fixture; the loader verifies
their provenance, report hash, sample counts, and values:

```bash
python3 scripts/pilot-load.py baseline \
  --profile quick \
  --report artifacts/pilot-load/quick/report.json
```

When no reviewed scheduled baseline is committed, scheduled CI explicitly uses
`run --capture-baseline`. It still runs the full 30-minute soak and all absolute,
differential, oracle, load, resource, and database gates, but reports
`baseline_review_required`. CI writes and uploads an unsigned
`candidate-baseline.json`; it does not attest, sign, import, or expose cutover
signing keys for that run. Candidate baselines cannot be loaded as regression
baselines or imported as cutover evidence.

After review, generate and commit the scheduled baseline from the downloaded
report:

```bash
python3 scripts/pilot-load.py baseline \
  --profile scheduled \
  --report /path/to/prior-run/report.json
```

The source must be a prior GitHub Actions report, contain at least 100 samples
for every stage and resources, and cover the full configured soak. An
authorizing scheduled run must have a distinct run ID and source commit from the
baseline. Future scheduled runs then compare against and sign that reviewed baseline. A baseline
can also be updated from a prior report whose only failures are against the old
baseline. The normal quick CI command never uses capture mode.

The absolute ceilings remain in `profiles.json`; they are never copied into a
measurement baseline. Updating a hardware regression baseline requires an
actual passing hardware run. Regression limits start from observed values and
use observed distribution spread (plus load-granularity allowance for sampled
pool/mailbox counters); absolute budget evaluation remains a separate gate.

The Apple-Silicon command requires macOS, an executable Swift provider, and
separate token files:

```bash
python3 scripts/pilot-load.py swift-hardware \
  --go-command "./coordinator-go" \
  --rust-command "./coordinator-rust" \
  --go-database-url postgresql://pilot_user:pilot_local_only@127.0.0.1:5432/pilot_go \
  --rust-database-url postgresql://pilot_user:pilot_local_only@127.0.0.1:5432/pilot_rust \
  --swift-go-auth-token-path /private/tmp/pilot-go-token.json \
  --swift-rust-auth-token-path /private/tmp/pilot-rust-token.json
```

Synthetic fault features are not silently emulated by the hardware command.
Requesting one with `--require-feature` fails before launch with a clear error.
Each provider receives an isolated copy of its explicit token file. The Rust
coordinator credential entry uses the exact Rust token sent by the Swift
provider, without a synthetic-session suffix.
The CI workflow uploads reports and logs but does not post pull-request
comments.
