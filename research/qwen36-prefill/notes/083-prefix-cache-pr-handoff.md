# 083 — Qwen exact prefix-cache PR handoff

Status: **clean branches built and fully tested; bot cannot publish nested
branch (GitHub 403)**

## Branches

### Nested `mlx-swift-lm`

```text
repository  Layr-Labs/mlx-swift-lm
base        main / ab73a827c9dde6f8802507003aa0be71605aab8e
branch      cursor/qwen-exact-prefix-cache-74d1
commit      8baffe4950ce18592f6d9becbd20ef7bea796e17
tree        c267de0434835bda4a40c1b8c4ddedffbebf1664
bundle      artifacts/qwen-exact-prefix-cache-8baffe.bundle
bundle sha  6f9fa713fa8ed4fe4836fbb128c23a52a76077ea3cd61cbf3342533fdfd621b8
```

The nested branch contains the exact durable cache plus default-off prompt
fork. Initial rollout must leave prompt fork disabled.

### Root `d-inference`

```text
repository  Layr-Labs/d-inference
base        master / 080d7e66782b28ab038f34dfb5ce23469f19642b
branch      cursor/qwen-prefix-cache-74d1
commit      740c137cd8c33bd989997447d9cc59666de52ef2
patch       artifacts/qwen-prefix-root-740c137c.patch.gz
patch sha   c97f34747b8dd49a3dac8f8ed4c3e0f0ee46d469612a0c0846f496b12f9f4bb3
```

The root branch contains only provider integration, telemetry/status/tests,
and the gitlink update. It excludes the autoresearch notes and rejected
experiments.

## Human publish sequence

The agent's nested push fails with:

```text
Permission to Layr-Labs/mlx-swift-lm.git denied to cursor[bot] (HTTP 403)
```

A collaborator can publish both bundles:

```bash
# 1. Nested repository
cd d-inference/libs/mlx-swift-lm
git fetch ../../research/qwen36-prefill/artifacts/qwen-exact-prefix-cache-8baffe.bundle \
  cursor/qwen-exact-prefix-cache-74d1:cursor/qwen-exact-prefix-cache-74d1
git push -u origin cursor/qwen-exact-prefix-cache-74d1

# Open nested PR: cursor/qwen-exact-prefix-cache-74d1 -> main

# 2. Root repository (only after the nested commit is remotely fetchable)
cd ../..
git switch -c cursor/qwen-prefix-cache-74d1 master
gzip -dc research/qwen36-prefill/artifacts/qwen-prefix-root-740c137c.patch.gz \
  | git am
git push -u origin cursor/qwen-prefix-cache-74d1

# Open root PR: cursor/qwen-prefix-cache-74d1 -> master
```

## Final clean-tree validation

The Mac checkout used exactly the clean root branch with nested commit
`8baffe4`:

- nested suite: **858 tests / 115 suites pass**;
- provider suite: **2,217 tests / 231 suites pass**;
- release `darkbloom` build: pass.

Artifacts:

- `artifacts/e55-nested-full-tests.txt`
- `artifacts/e55-provider-full-tests.txt`
- `artifacts/e55-provider-release-build.txt`

## Initial rollout posture

```bash
DARKBLOOM_EXACT_PREFIX_CACHE=1
DARKBLOOM_EXACT_PREFIX_CACHE_MAX_BYTES=2147483648
DARKBLOOM_EXACT_PREFIX_CACHE_MAX_FRACTION=0.125
```

Keep `DARKBLOOM_CBV2_PROMPT_FORK` unset.

The profile is default-off, Qwen-capability-gated, contiguous-backend-only,
tenant-scoped, model/prompt/policy-identity-bound, and charges resident plus
in-flight donation bytes to one hard carve.

Measured tradeoff:

- 75%/87.5% exact-prefix TTFT: 2.629x / 5.076x versus native;
- canonical/native blind quality: 99.56%;
- cache-enabled cold misses: ~1.5x slower;
- cache-free engines: unchanged.

Roll out to a small Qwen-only cohort and retain only where exact-prefix hit
rate covers the cold-miss tax.
