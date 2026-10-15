# Current distributed delivery checkpoint — 2026-09-15 23:00 UTC

Goal remains ACTIVE, not complete. User requested a status update; this does not cancel the build-and-ship goal. Plan-first already fulfilled. Full access is authorized, no repeated permission/password questions. No production release/push/deploy has happened. Preserve existing work; do not reset MLX submodules or discard the retained stash.

## Current stage

Working real 9B distributed native runtime plus newly integrated local Provider/CLI serving; live installed-product HTTP qualification is NEXT. Current test cluster is M4 Pro 24 GB + M4 Pro 48 GB, both reachable by authenticated SSH at 22:54 UTC. No M3 Ultra hardware. Larger models and active MTP are not qualified. Current ordinary product profile is serial prefill, two ranks, B1, greedy, MTP off, 8192 prompt / 128 output / 512 chunk / 8320 context; max 300-second resident lifetime including startup and 16 requests. Lookahead is still Benchmark SPI only.

## Latest MAIN changes and verification

Repo /Users/developer/DarkbloomDev/d-inference, feat/cluster-inference, HEAD605651bb95d71c1da9bb122107925143e9441973 (master merged earlier). Changes are uncommitted.

31 reviewed installed-session, HTTP-host and CLI files promoted together with exact baseline/hash checks and backups in distributed-start-main-integration-20260915/promotion.json. Input installed manifest391122640456c33e9a7f0a426cdb62f4bf4b7345179c3b068903c1b3a6a55cb6; host V2 manifest2366713f577e42afeed042754522c747178938c6bede1c44b37de65bbb612c41. CLI/host review3f02ba844b95061d0a4ab0fa6f2dd2218a438523535cada94ed168f9662210c0; independent installed/host API review also no concrete blocker.

- Actual full Provider/CLI compilation plus75 selected tests/11 suites PASS, including12 HTTP lifecycle methods. Receipt distributed-start-main-integration-20260915/provider-tests-2, elapsed24.7438s, Package.resolved unchanged b2b12d24d48bbedc4583d8831e0b81fe68b96d641804e0ebc56715cd2d88a7ea.
- First combined attempt built successfully but one fixture failed because Foundation normalized /private/var through /var symlink. MAIN test-only fixture now uses private UUID dir under cwd, like existing configuration checks. No-follow product validation unchanged. Frozen original preserved; provider-test-fixture-fix.json records delta.
- Actual MAIN ProcessChecks PASS27.6189s; RemoteChecks PASS11.3619s; SSHChecks PASS17.2065s. control-tests-1 retains logs/receipts. These use real local process fixtures, not physical Macs.
- Latest docs-check --all PASS300 files and git diff --check PASS after CLI/config/CHANGELOG docs promotion. Docs manifest3d2de774d53477d4166933d9cb866b613f3bf8a058f4894ac32ebe6b16637939, receipt distributed-cli-configuration-docs-main-integration-20260915/promotion.json.
- No root exec/test/native/owner sessions remain. Heavy compiler is free except transport agent may now run small Foundation fixtures.

## Product behavior now in source

cluster configure persists inert pinned setup. start --local --distributed branches before solo model/Metal preparation and native device gate; unsupported solo overrides refuse. Explicit alternative config must select the same cluster reference as the default provider.toml, because fixed installed cluster worker-owner --stdio reads that default.

Leader prepares pinned metadata and tokenizer only, launches local installed owner plus direct authenticated SSH peer owner. No opaque caller readiness/capacity/native environment. Session owns all endpoints from partial startup through cleanup; requires native cleanup, authenticated lease ACK and natural owner exit0. Unresolved ownership quarantines. Pair enforces capability quota16; final active request remains valid; drain stops new reservations and waits explicit release. Endpoint now allows bounded2s natural exit grace after authenticated release instead of killing a successful owner immediately.

HTTP host uses existing OpenAI stack, auth/SSE, bind-confirmed discovery and one acquisition pin. No auto epoch rotation. Stops on idle lifetime/quota exhaustion, preserves cleanup ownership, reports bounded quarantine to CLI, and latches unexpected runtime failure even if cleanup later succeeds. CLI owns signals before launch and does not convert unresolved cleanup into success. The normal local/foreground solo process holds shared native-device exclusion until process exit.

External TTFT origin is captured before auth/body decode and forwarded through tokenization/queueing. Explicit distributed local start selects10,000ms+1ms per token budget. Internal origin is not OpenRouter send time; external client measurement still required. General coordinator ProviderLoop/distributed capacity/accounting integration is still open.

## Real physical evidence completed

See repository reports2026-09-15-cluster-resident-generation-correctness.md, cluster-lookahead-generation-and-timing.md and new cluster-cancellation-recovery.md.

Serial and one-chunk-lookahead each matched all128 selected token IDs, final496640BF16 bytes and all72 final state digests against full single-Mac reference for pinned 8192-token diagnostic prompt. Final selected hash892e92cbcb8da5e696ceddb2d8e9bcf57b7c4f4f16cea15d215c4d28303c8456. Intermediate rows/state are not fully exported; fresh repeated UUIDs use token-sequence guard only.

Matched three-sample warm cohorts with wakeup owner: serial median19.231474125s /425.968386 prompt TPS /22.887452 continuation TPS; lookahead16.583442167s /493.986708 prompt TPS /22.903208 continuation TPS. Old poll pump decode was about11TPS. These are internal request.start-to-first-committed-token timings, not external HTTP/OpenRouter, not sustained/representative workload qualification. Solo one-output baseline441.68TPS uses a different output condition and is not a matched128-token speedup claim. M3 Ultra27B800desired/1000stretch remains unvalidated projection target.

Both physical cancellation cases PASS: before first token at0.530562541s after request.start, and after ordinal1 prefix[271,8839]. Each held2,216,442,591 reserved bytes until actual retirement; completed cleanup/ACK; then fresh Pair/epoch recovered expected128tokens. Both alias/postflight/journals/children checks pass.607 samples AC, zero swap, pressure1, >=6GiB actualfree. May include owned fencing, not cooperative-only proof, no observed GPU kernel phase. Report now MAIN (SHAe25896ac54573693569422575190e7c6ba67c3d025ef7177a198739c64e72af7). Broader peer/link loss remains open.

## Machines and artifacts

Operator SSH aliases darkbloom-24 developer@192.0.2.250 and darkbloom-48 developer@192.0.2.223; key ~/.ssh/id_ed25519_darkbloom_dev, persistent mux. Private credentials in /Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md. Never print passwords or pass them in argv. Both remote Mac16,7 M4 Pro14CPU20GPU macOS27.0build26A428. Local development M4Max36GB.

NEW direct peer SSH verified both directions: each has /Users/developer/.ssh/id_ed25519_darkbloom_cluster (private0600), restricted public key installed on other, pinned known-hosts file /Users/developer/.ssh/darkbloom_cluster_known_hosts SHAe391f06908f452e59dee97b1a7a631d80c57d2844ddf7f4d8d0e78d2eb3d617a. No private key transfer. Receipts installed-cluster-access-20260915; private machines/README.md updated.

Both models /Users/developer/DarkbloomDev/models/Qwen3.5-9B. config c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423 (3118B), manifest4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4 (2685B). Actual24 hashes reverified this turn. Artifact127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b. Cut4/28 Plan67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f.

Latest MAIN native release worker b8335e55de6e681e9b1b7be6ae6a64e57380cc20b3d6e6c13587517afee0a1d1, preserved resident-main-lookahead-worker-bundle-20260915. Local actual --describe-runtime PASS, descriptor26fa98e8d1c59f83318f806c30b81381b868818a2cb9274f49150e4b5644577e in resident-prefill-lookahead-main-integration-20260915/native-metadata-2. NOT installed remotely yet. Latest Provider debug binary built at provider-swift/.build/debug/darkbloom, not yet preserved/pinned/installed.

Remote serial capability runtime569f2a4b... at resident-capability-runtime-20260915; private benchmark lookahead009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b at resident-lookahead128-runtime-20260915 used for timing/cancellation. Do not mix these pins with newb833 descriptor. Matched metallib2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2.

TB24en1 IPv4169.254.70.46/16;48en1/bridge0 lacks IPv4-mapped GID normally. All physical runs use approved bounded48 alias169.254.70.47/32,600s lease, same guard from run_resident_physical_attempt9_alias_20260915.py, restore verified. No bridge resets/reboots/permanent network edits. Maintain >=6GiB actualfree, zero swap, AC/pressure/thermal guard. Root owns all physical/native/heavy compiler coordination.

## Immediate next work

1. CLI/config/CHANGELOG docs overlay has been reviewed, hash-verified and promoted. All300 docs and whitespace checks PASS. Arithmetic agent idle; no further docs promotion needed for this step.
2. pipeline agent preparing exact per-member product config templates and hardware qualification plan from b833 metadata; explicit fresh owner/worker install path placeholder until actual Provider artifact pin. Source-only, no remote writes.
3. transport agent preparing repository-owned reproducible InstalledSession Foundation lifecycle fixtures (currently private checks-7) using exact MAIN sources. No native/network/main edits.
4. Preserve/pin newly built Provider andb833 native bundle; install fresh development paths on BOTH Macs; back up default provider configs before actual configure. Keep current standalone/production setup reviewable. Run resource-guarded actual start --local --distributed and external HTTP client tests on leader, then cancellation/cleanup/fresh startup. Defaults serial; do not silently enable Benchmark lookahead.
5. Finish long-running service rotation/reconnect, wider peer/link failure tests, public lookahead capability/scheduling promotion, matched solo/distributed and real external TTFT percentiles, actual MTPoff/on, adapters27B/Gemma26B(and35Blater), coordinator capacity/accounting, status/doctor/recovery/setup docs and compatibility/release evidence. Do not call milestone1 complete yet.

Older detailed provenance and historical intermediate blockers are preserved in CLUSTER_DELIVERY_NEXT.pre-start-integration-20260915.md; this checkpoint supersedes its stale current-state paragraphs.
