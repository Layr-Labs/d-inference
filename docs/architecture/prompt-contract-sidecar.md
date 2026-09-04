# Prompt-contract sidecar

> Last updated: 2026-09-03 · commit `5d400cf75`

The prompt-contract sidecar derives deterministic, provider-compatible token
boundaries for optional exact-cache routing. The inference path consults it
only when routing mode is `on`, the request is inside the operational rollout
cohort, every active artifact has been provisioned, and the request's contract
has been explicitly preloaded. A disabled, unhealthy, overloaded, timed-out,
or malformed sidecar always fails cold and cannot block ordinary inference.

## Process and lifecycle

The coordinator starts `promptsidecar` as its child only when
`EIGENINFERENCE_PROMPT_SIDECAR_ENABLED=true`. It creates the socket directory
with mode `0700`, passes only bounded numeric settings and local paths, and uses
separate probes and transports for liveness and readiness. `GET /health` is a
cheap liveness probe that remains responsive while contracts load;
`GET /ready` gates cache planning until preload succeeds. Planning, health,
startup/preload, and shutdown have independent deadlines. A single missed
health probe never restarts the child: the supervisor requires a configured
consecutive-failure threshold, records the categorical restart reason and exit
status, retains only a bounded stderr tail, and applies restart backoff/circuit
protection. Shutdown sends `SIGTERM`, then kills a child that exceeds the
bounded shutdown deadline. On Linux the child also installs
`PR_SET_PDEATHSIG` and verifies the supervisor PID, so a coordinator crash
cannot leave an orphan retaining the socket.

The production safety controls are explicit:

| Variable suffix after `EIGENINFERENCE_PROMPT_SIDECAR_` | Default | Purpose |
|---|---:|---|
| `TIMEOUT_MS` | `1000` | Per-plan deadline and planning transport |
| `HEALTH_TIMEOUT_MS` | `250` | Liveness/readiness probe deadline on an independent transport |
| `PRELOAD_TIMEOUT_MS` | `120000` | Complete active-set preload deadline |
| `STARTUP_TIMEOUT_MS` | `120000` | Time allowed for the child to establish liveness; degraded readiness does not trigger a restart |
| `HEALTH_INTERVAL_MS` | `1000` | Probe interval |
| `HEALTH_FAILURE_THRESHOLD` | `5` | Consecutive post-liveness failures required before restart |
| `RESTART_WINDOW_MS` / `RESTART_MAX_IN_WINDOW` | `60000` / `3` | Restart-loop circuit window and maximum |
| `RESTART_COOLDOWN_MS` | `30000` | Minimum suppression after the circuit opens |
| `STDERR_MAX_BYTES` | `16384` | Retained child stderr tail |
| `MAX_LOADED_CONTRACTS` | `8` | LRU and explicit active-set bound |
| `MEMORY_LIMIT_MIB` | `1024` | Linux address-space and observed RSS ceiling |
| `SHUTDOWN_TIMEOUT_MS` | `2000` | `SIGTERM`-to-kill grace on shutdown |

`promptcontract.ReadSupervisorConfig` (`coordinator/promptcontract/config.go`)
also reads the non-safety knobs — `ENABLED`, `BINARY`, `SOCKET`,
`ARTIFACT_ROOT`, `ARTIFACT_BASE_URL`, `ARTIFACT_TIMEOUT_MS`,
`PROVISION_WORKERS`, `PROVISION_MAX_MODELS`, `HEADER_TIMEOUT_MS`,
`RESTART_MIN_MS`, `RESTART_MAX_MS`, `MAX_BODY_BYTES`, `MAX_CONCURRENCY`,
`MAX_CONNECTIONS`, `MAX_TOKENS` — with the defaults given there.

The sidecar serves HTTP/1.1 only on
`/run/darkbloom/promptsidecar.sock`. The socket is mode `0600`; there is no TCP
listener and no network client. Connections stay alive and the Go client pools
them. A 4 MiB request-body limit, 64-connection limit, four-worker planning
semaphore, 1,048,576-token limit, eight-contract artifact cache, one-second
request deadline, and (on Linux) 1 GiB address-space limit bound resource
consumption.
Completed connection tasks are reaped continuously. Contract misses use a
per-contract singleflight: one worker performs file verification/tokenizer
construction and concurrent callers wait for that same result. Distinct
contracts remain bounded by the planner semaphore and LRU capacity.

At startup the sidecar binds its socket and reports live but not ready; it does
not discover or load every directory left on disk. After asynchronous artifact
provisioning finishes, the coordinator sends the complete, deduplicated active
set to `POST /v1/preload`, which loads that set sequentially before traffic.
This prevents stale contracts from consuming the bounded cache during a
restart. The endpoint serializes preload runs, stops new plans while swapping
readiness, rejects sets larger than the configured contract capacity, and
reports only bounded cold/warm/failure results. The Go preload gate records the
child generation and will not route a model until its contract succeeded in
that generation. A fresh or stale artifact root is live but has no
planning-eligible contract until this explicit handoff completes.

Prompt artifacts live at `/mnt/disks/userdata/prompt-contracts`. The verified
artifact loader rejects symlinks in every path component, so `/data`—a runtime
symlink to the persistent disk—must never be used as the artifact root.

`POST /v1/plan` accepts:

```json
{
  "prompt_contract_id": "<64 lowercase hex characters>",
  "scope_id": "<authenticated cache scope>",
  "endpoint": "chat_completions",
  "body": {}
}
```

It returns the contract identifier, prompt token count, ordered 256-token chain
boundaries, and the last lookup-eligible boundary. The normalized body and token
IDs remain transient and are not returned by the service. The offline fixture
generator is the only interface that emits token IDs.

## Contract identity

`prompt_contract_id` is SHA-256 over this binary encoding:

1. `u32be(length) || bytes` for the domain
   `darkbloom.prompt-contract.v1`.
2. `u32be(artifact_count)`.
3. For artifacts sorted by `(role, path, sha256)`, length-prefixed UTF-8 role,
   length-prefixed UTF-8 relative path, and a length-prefixed 32-byte digest.
   Only manifest roles `config`, `template`, and `tokenizer` participate.
4. Length-prefixed name and value pairs for `normalization`, `renderer`,
   `tokenizer`, and `block_hash`.
5. Length-prefixed `block_size` followed by `u32be(256)`.

The semantic versions are:

- normalization: `darkbloom-request-normalization-v2` (includes Gemma 4 tool-schema, argument, and turn-structure compatibility)
- renderer: `swift-jinja-compatible-v1`
- tokenizer: `huggingface-tokenizer-json-v1`
- block hash: `darkbloom-block-chain-v1`

Changing an artifact digest, path, role, semantic implementation, or block size
creates a different contract.

The artifact loader records the pinned `swift-transformers` precedence:
`chat_template.jinja`, then `chat_template.json`, then the tokenizer-config
value. V2 readiness is intentionally narrower: the provider advertises an exact
prompt contract only when `chat_template.jinja` exists and passes the real
serving-render checks. Alternate template sources stay cold until their
multi-template selection and Swift compatibility rewriting are proven by the
same production gate; their hashes still remain part of artifact identity.

## Block-chain encoding

For block index `i`, the engine, Go package, and Rust sidecar compute:

```text
SHA256(
  "darkbloom.prefix-block-chain.v1" ||
  field(prompt_contract_id) ||
  field(scope_id) ||
  parent_hash_32 ||
  u32be(i) ||
  u32be(token_0) || ... || u32be(token_n)
)
```

`field(x)` is `u32be(byte_length(x)) || x`; the fixed domain is unprefixed and
the first parent is 32 zero bytes. Only complete 256-token blocks are hashed,
so the token sequence has an invariant length and needs no count field.
Lookup always reserves the final token, so an exact 256-token prompt has no
eligible boundary, 257 tokens has the 256-token boundary, and 512 tokens still
uses only the 256-token boundary. Swift SSD data is DBK3 — header version 3,
extension `.dbk3`, root `darkbloom/kv3`, layout epoch
`cbv2-frozen-full-3|native-fp|<blockSize>|<digest>` (`SSDBlockStore.layoutEpoch`);
other header versions are rejected. See
[`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md).

## Artifact handoff and threat model

The Go cache accepts catalog manifest data, filters to prompt roles, verifies
the model aggregate identity, downloads each declared file from the configured
HTTPS origin, rejects cross-origin redirects, verifies size and SHA-256 while
writing, fsyncs files and directories, and atomically renames a random
same-root temporary directory. `os.Root`, exclusive creation, relative-path
validation, and symlink checks contain traversal. Published files are mode
`0400` and directories mode `0500`; every reuse re-hashes every artifact.

The Rust process never downloads. It opens every path component from `/` with
`O_NOFOLLOW`, so a symlink anywhere in the artifact path is rejected; it
rechecks sizes and hashes, verifies metadata and contract identity, and loads
only a coordinator-published contract directory.

Protected failures include malicious JSON, oversized or slow bodies, unsafe
paths, symlinks, changed artifacts, wrong contracts, incompatible templates,
unsupported tokenizers, child crashes, stale sockets, process hangs, and
malformed responses. Errors contain fixed categories and never include request
bodies, rendered prompts, token IDs, or hashes. Cache routing treats every such
failure as ordinary cold routing.

`GET /metrics` returns a bounded JSON snapshot for the local coordinator:
planning success/failure/capacity/timeout counts and latency buckets,
cold/warm/waited/failed contract loads and cold-load latency, preload runs, and
cache occupancy. It contains no model IDs, contract IDs, accounts, scopes,
prompts, tokens, or chain hashes. Public status projects only aggregate values.

Templates that call `strftime_now` are deliberately ineligible: the pinned
Swift renderer evaluates that function in each provider Mac's local timezone,
so a central process cannot derive the same prompt for every provider near a
date boundary. The sidecar returns a fixed planning failure instead of claiming
an exact cache key for dynamic provider-local input.

## Parity fixtures and measured latency

`fixtures/prompt-contract/v1` is shared by Rust, Go, and Swift tests for
contract and block-hash vectors. `corpus.json` contains complete requests for
tools, null sanitization, Harmony and Gemma normalization, reasoning effort,
Unicode, all four endpoints, exact block multiples, and long prompts.

Production tokenizer/template/config artifacts are not stored in this
repository. Generate the mandatory per-model normalized bodies, token IDs, and
boundaries only from manifest-pinned, coordinator-provisioned artifacts:

```bash
cd coordinator/promptsidecar
cargo run --locked --release --bin prompt-fixtures -- \
  --manifest /immutable/catalog/model-a.json \
  --manifest /immutable/catalog/model-b.json \
  --artifact-root /mnt/disks/userdata/prompt-contracts \
  --cases ../../fixtures/prompt-contract/v1/corpus.json \
  --output ../../fixtures/prompt-contract/v1/production_vectors.json
```

`scripts/verify-prompt-parity.sh` replays the checked-in manifest snapshot in
`fixtures/prompt-contract/v1/manifests/` (with `PROMPT_PARITY_UPDATE=1` it
re-snapshots every active public manifest and rewrites the inventory), downloads
only the verified prompt artifacts through `coordinator/cmd/promptfixtureinput`,
regenerates the vectors with `prompt-fixtures --manifest-directory`, and `cmp`s
them byte-for-byte against `production_vectors.json`; it then runs the Swift,
Go, and Rust parity tests and drives the release binary through the real Go
supervisor (`coordinator/cmd/promptsidecarloadproof`). Eligible models must
produce every required request shape and exact token-count case through Rust
and the real Swift provider prompt pipeline. Models with provider-local dynamic
time stay in the inventory with `cache_routing_eligible: false` and
`ineligibility_reason: "dynamic_time"` (written by `prompt-fixtures`), have no
routable vectors, and must fail provider contract readiness
(`PromptContractIdentity.compute(modelDirectory:)`). Missing models, artifacts,
cases, or unrecognized incompatibilities fail the gate; no fabricated token IDs
are accepted.

Latency is enforced by `coordinator/promptsidecar/tests/planner_fixture.rs`
(`measure_fixture_planning_latency`, `measure_fixture_unix_http_latency`): 1,000
warm plans of the 256-word local fixture, asserting `p99 <= 250 × p50` and
`16 × p99 <= 1 s` for both the in-process planner and the persistent Unix
HTTP/1.1 path. A one-off 2026-07-14 run of that harness (arm64 Apple Silicon
release build, Rust 1.88.0) recorded 72 µs p50 / 133 µs p99 in the planner and
82 µs / 168 µs over HTTP including JSON work; CI checks the ratios, not these
absolute figures, and neither includes production model cold-load cost. The
one-second deadline leaves the enforced ≥ 16× p99 margin until manifest-pinned
production measurements replace the synthetic gate.
