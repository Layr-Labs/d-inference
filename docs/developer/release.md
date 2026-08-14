# Release

## Provider bundle

The provider bundle is built and signed in CI via
`.github/workflows/release-swift.yml`.

High-level flow:

1. Build `darkbloom`, `darkbloom-enclave`, and `darkbloom-fan-helper`.
2. Sign each nested executable with its own identifier, then sign the outer app with the Developer ID Application certificate.
3. Notarize with Apple.
4. Compute SHA-256 hashes **after** code signing.
5. Upload to R2.
6. Register the release with the coordinator.

> **Important:** hashes must be computed after code signing, not before.
> Providers verify the hash of the signed binary during install.

Bundle creation, resource staging, helper signing, notarization, and final
archive checks live inline in `.github/workflows/release-swift.yml`; there are no
standalone bundle scripts. `scripts/install.sh` is the end-user installer served
by the coordinator.

For v0.7.9+, the workflow places the fan helper only at
`Darkbloom.app/Contents/Helpers/darkbloom-fan-helper`, signs it as
`io.darkbloom.fan-helper` without provider APNs/keychain entitlements, and seals
the `fan-helper-v1` capability marker. It must never appear in the flat `bin/`
verifier layout or be privileged-installed by CI/the ordinary installer.

## Coordinator release

Production and dev both run on GCP in separate projects. Production is the
approval-gated `darkbloom-mainnet` GCE deployment; dev is `sepolia-ai`.

### Prod (GCP, human approval required)

```bash
git push origin master
gcloud builds list --project=darkbloom-mainnet --limit=5
```

The repository trigger uses `deploy/gcp/cloudbuild-prod.yaml` and binds the
uploaded source, OCI revision label, and image tag to `COMMIT_SHA` /
`SHORT_SHA`. Direct `gcloud builds submit` from a local tree is rejected. The
trigger builds and pushes only; a human operator or explicitly human-approved
agent performs the container swap from
[operations/coordinator-deploy.md](../operations/coordinator-deploy.md).

### Dev (GCP)

```bash
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
```

See `operations/dev-environment.md` for full dev environment setup.

## Version gate

`coordinator/api/server.go` contains `LatestProviderVersion`. Provider update
checks and `minProviderVersionForDesiredModels` must stay coordinated with the
uploaded bundle version.

`scripts/check-release-version.sh` is the release invariant. CI and
`release-swift.yml` require the tag/dispatch version, `ProviderCore.version`,
`LatestProviderVersion`, built CLI `--version`, and final app plist to agree.
The release workflow validates source; it does not rewrite it.

## Console UI release

The console UI deploys automatically to Vercel on pushes to `master`.

```bash
make ui-build
```

## Release performance gate

Pull requests run `.github/workflows/integration.yml`. The `E2E Benchmarks` job
uses the protected `benchmarks` GitHub Environment and requires human approval;
release preparation must not bypass that gate.

Local non-production reproduction:

```bash
cargo build --manifest-path coordinator/promptsidecar/Cargo.toml --release
go test ./e2e -run TestIntegrationExactCacheRouting -count=1 -v -timeout 30m
go test ./e2e -run TestBenchmark -count=1 -v -timeout 30m
```

The sidecar request deadline (`EIGENINFERENCE_PROMPT_SIDECAR_TIMEOUT_MS`) and
provider SSD stage deadline (`DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS`) are
functional upper bounds, not performance claims. Cache-hit and miss latency
acceptance requires a positive-hit-capable real model. Contiguous,
unquantized Gemma 4 and GPT-OSS slots now use frozen-full replay; paged hybrids
remain cold-only
(`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift:289-317`;
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/PrefixReusePlan.swift:127-153`;
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/FrozenReplayFullSequenceKV.swift:54-99`).
Protected benchmarks and human approval are still mandatory before routing
activation.

Local M4 release-preparation evidence on 2026-07-17:

- Rust planner fixture: p50 146 µs, p99 562 µs.
- Persistent Unix HTTP planning: p50 165 µs, p99 595 µs.
- Real encrypted DBK3 fixture: miss p95 0.145 ms, hit-stage p95 9.182 ms.

Frozen-full local evidence from 2026-07-19 is recorded in
`docs/reports/2026-07-19-frozen-full-prefix-cache-proof.md`.

The automated gates are derived from the configured one-second planning/stage
deadlines; the Rust gate additionally requires at least a 16× p99 safety
factor. These are contract-derived bounds, not guessed per-machine constants.

## Release-sensitive sync points

- Provider bundle semantics: keep `.github/workflows/release-swift.yml`,
  updater capability verification, and `LatestProviderVersion` in sync.
- `scripts/install.sh` is the installer source of truth.
  `coordinator/api/install.sh` is a byte-identical generated embed; run
  `scripts/sync-install-embed.sh` after installer changes.
- Install paths or process invocation changes must update both the CLI and the
  install flow.
- Model registry changes span coordinator registry, provider manifest code,
  `scripts/publish-model.sh`, and the console UI.
