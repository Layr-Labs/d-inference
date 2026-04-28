# Release Pipeline — Status & Roadmap

The release workflow at `.github/workflows/release.yml` builds, signs, notarizes, and publishes the provider bundle + macOS app per dev or prod environment. This doc tracks what's been optimized and what's still on the table.

## Current state (phase 1 — landed)

Wall-clock: **~18–22 min warm, ~22–25 min cold**. Down from ~30 min pre-refactor.

Structural choices:
- `coordinator-tests` runs on `ubuntu-latest` in parallel with the macOS build. Keeps pure-Go work off `macos-26-xlarge`.
- Rust toolchain outputs (`~/.cargo/registry` + `provider/target/`) cached via `actions/cache` keyed on `Cargo.lock`. Cold builds unchanged; warm ~4 min faster.
- Python runtime build runs concurrently with Apple notarization via shell backgrounding in a single step. The notarize call is ~3–8 min of remote wait; the Python build is ~5 min of local pip install + signing. Running them in parallel cuts ~5 min from the critical path.
- `codesign` batch retries once on transient Apple timestamp-service failures (30s backoff). Prevents full-workflow rebuilds on Apple flakes.
- R2 uploads parallelized (bundle + python + site-packages + vllm-source, plus versioned + `latest` DMG paths).

Machines:
| Job | Runner | Spec |
|---|---|---|
| `build-and-release` | `macos-26-xlarge` | Apple Silicon, 12 vCPU, 30 GB — largest standard GH-hosted macOS tier |
| `coordinator-tests` | `ubuntu-latest` | 4 vCPU, 16 GB |
| `resolve-env` | `ubuntu-latest` | same (trivial, doesn't matter) |

Apple-bound work (~15 min of ~20) is the critical floor that no amount of bigger hardware shortens.

## Phase 2 — de-duplicate Python work (next)

**Target**: ~20 min → ~14–16 min. Biggest ROI, minimal infra.

1. **Share the signed Python tree between the provider bundle and the macOS app.**  
   Today we build Python twice: once for `/tmp/darkbloom-build-python` (libpython linkage for the Rust binary) and once for `$PYTHON_ROOT/` in the macOS app (full vllm-mlx runtime with `.so` signing). The second cycle re-signs every Python Mach-O individually. Build + sign once, reuse the signed tree for both consumers.
2. **Cache the signed Python runtime across releases.**  
   It only changes when `requirements.txt`, the vllm-mlx fork, or `PBS_PYTHON_VERSION` changes — maybe once a week. Key a cache on a hash of those inputs. Subsequent releases skip ~5 min of pip install + Mach-O signing.
3. **Conditional macOS app build.**  
   If a release commit doesn't touch `app/Darkbloom/**`, skip building the DMG and reuse the previous release's DMG pointer in the registration payload. Saves ~7 min on provider-only releases.

Implementation: all three are in-workflow changes plus one `actions/cache` entry. No new jobs.

## Phase 3 — split into parallel jobs on separate runners

**Target**: ~14–16 min → ~10–12 min. 2× macOS minutes cost for ~4 min wall-clock win.

Restructure the one macOS job into three concurrent macOS jobs:
- `build-provider`: Rust + enclave + provider bundle sign + notarize + upload.
- `build-python-runtime`: pip install + sign + hash. Emits an artifact consumed by `build-macos-app`.
- `build-macos-app`: needs the two above; Swift app + DMG + notarize.

Plus an `ubuntu-latest` `register-release` job that fans in once provider + runtime are done (doesn't need to wait on macOS app).

Artifact transfer cost: ~30–60s per handoff. Critical path becomes `max(build-provider, build-python-runtime) + build-macos-app`.

Defer until phase 2 is exhausted — cheaper to eliminate work than to parallelize it.

## Phase 4 — self-hosted macOS runner

**Target**: ~10–12 min → ~5–7 min. Requires owning + maintaining hardware.

Put a Mac Studio M4 Max (or similar) on the network as a persistent self-hosted GitHub Actions runner.

Wins:
- Zero runner queue time (GH-hosted Apple Silicon xlarge can take 30–120s to start).
- Persistent keychain — skip cert import every run (~30s + security ritual).
- Persistent cargo target, Xcode derived data, Homebrew. First build after a cache purge is still cold, but ~90% of builds hit a fully warm machine.
- Faster local disk (NVMe), more CPU cores than xlarge.

Trade-off: you maintain the machine, Xcode updates, runner token rotation, and security isolation from other workloads. Worth it only if release cadence is daily-or-more-often.

## Phase 5 — restructure the release model

**Target**: ~5–7 min → ~2–3 min. No longer a pipeline tweak — it changes what "a release" means.

1. **Split provider bundle release from macOS app release.** Different cadences, different workflows. Provider ships every commit; app ships when UI changes.
2. **Pre-notarize a stable base layer** (Python runtime + enclave helper) as a versioned artifact that the main release references by hash. Only the ~20 MB top layer (darkbloom binary + stt_server.py + ffmpeg) gets freshly notarized per release. Notarize time drops from ~5 min to ~60–90s (Apple's floor).
3. **Coordinator cross-references artifact manifests** rather than a single monolithic URL per release, so providers can download layers independently with independent verification.

## The floor

Below ~2–3 min you're constrained by:
- Apple's notarization roundtrip minimum (~60–90s even for a tiny payload)
- R2 upload for the bundle
- Coordinator registration API call

You can't notarize instantly, and you can't skip notarization without losing the "hardware trust level" guarantee on prod providers.

## Recommended order

1. Phase 1 — landed.
2. Phase 2 next.
3. Skip phase 3 unless daily releases make the 2× spend worth ~4 min.
4. Phase 4 when releases become a daily thing.
5. Phase 5 is a release-model discussion, not a pipeline one — revisit after you're shipping regularly.
