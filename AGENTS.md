# Darkbloom Provider And Native Runtime

This repository owns the Swift provider, device-local APIs, MLX/native runtime
integration, public fixtures, provider release tooling and the landing site.
Start with `docs/README.md`; documentation rules are in `docs/AGENTS.md`.

## Workspace And Ownership

Use sibling checkouts under one workspace:

```text
Darkbloom/d-inference
Darkbloom/darkbloom-platform
```

Never nest the repositories or relocate an existing checkout incidentally.
Centralized coordinator/backend, Rust prompt sidecar, consumer-console and
admin changes belong exclusively in `darkbloom-platform`. Never implement,
commit, push or upload that code to `d-inference`. Provider-local Swift services,
HTTP APIs and native execution remain here. Verify `git remote -v`, branch,
status and the full intended diff before publishing anything.

Source ownership does not grant deployment authority. Retained release/model
publication scripts call external APIs; they do not authorize building, testing
or deploying the backend here. Infrastructure and hosting changes require
specific human approval.

## Layout And Validation

| Path | Responsibility |
|---|---|
| `provider-swift/` | Provider CLI, security, local services, inference and tests |
| `libs/` | MLX, MLX-Swift and MLX-Swift-LM gitlinks |
| `landing/` | Independent Next.js marketing app, including its API routes |
| `fixtures/` | Public fixed-input contracts, not backend implementations |
| `scripts/` | Native qualification, provider builds/install/publication and repository checks |
| `docs/` | Provider/native docs and immutable historical evidence |

Use `mise.toml` and `Makefile`: `make provider-build`, `make provider-test`,
`make landing`, `make docs-check`, and `make docs-impact-check BASE=<target>`.
Follow `docs/developer/build.md` and `docs/developer/test.md` for focused native
checks. Do not run tests against production, real accounts or real credentials.
Keep test daemon state, recovery records and cache files isolated from live
providers. Public golden-vector checks prove agreement with fixed expected
outputs, not live cross-implementation parity. Private platform qualification,
real Apple attestation and full-model GPU evidence remain distinct gates.

## Cross-Repository Contracts

- Protocol, telemetry, model manifests, capacity quotations and release identity
  changes require coordinated review with the platform owner. Keep enum casing,
  optional-field omission, units and lifecycle semantics aligned. Do not copy
  backend code here or fetch a moving private branch in ordinary provider CI.
- `ProviderCore.version` is the local release authority. Coordinate the platform
  version snapshot/fallback separately; no local backend source constant is
  required. Keep tags, built binary versions and signed artifact identity aligned.
- Preserve the installer and platform-served snapshot contract through explicit
  reviewed updates. Never silently overwrite the platform's copy.
- API registration is not deployment. Missing latest-release rows can make
  installation/update fail even when a version constant is correct. Preserve
  post-signing hashes, exact artifact qualification and registration checks.
- Published catalog manifests determine model bytes. Do not introduce a
  hardcoded provider model catalog or treat successful upload as model quality.

## Native Safety Invariants

- Build `mlx.metallib` from the MLX source nested in `libs/mlx-swift/Source/Cmlx/mlx`,
  which is what Cmlx compiles. Bumping top-level `libs/mlx` alone changes no provider bytes.
- Keep fast startup discovery separate from on-demand weight hashing. Preserve
  template render checks and explicit failure reporting; never auto-repair templates.
- Drive the Qwen vision tower one image at a time. Its unfused attention can
  allocate quadratic score tensors. Keep the prefill under `MLX.withError` and
  check every `eval` using `throwIfMLXFaulted`; the handler records and returns.
- Preserve unified-memory OS/activation/KV safeguards and full LOAD quotations,
  including validated Qwen4/MiMo transient supplements. Measured residency is
  not a substitute load allowance. Activation floors are measured constants,
  not shape formulas; unmeasured/vision members retain the conservative floor.
  Coordinate floor and capacity semantics with platform admission.
- Preserve cache encryption, owner-only paths, volume identity, missing-disk
  refusal, daily write accounting and bounded retirement. Read the current
  `docs/provider/cache-storage.md` and `docs/architecture/security/encryption.md`.
- Never include prompt/completion content, token IDs or media in telemetry or
  heartbeats. Do not claim sender sealing hides plaintext from the coordinator
  or the provider process.

## Code Structure And Quality

Keep modules domain-owned, cohesive and explicit. Separate transport, policy,
persistence and presentation where they have distinct responsibilities; keep
entry points thin. Prefer small single-responsibility files, but do not scatter
one operation across tiny helpers merely to reduce line counts. Extract helpers
for meaningful operations or real reuse, not speculative frameworks.

Choose the smallest correct change. Use precise names, explicit dependencies
and readable guard clauses. Preserve public contracts, failure cleanup,
concurrency schedules, ownership, cancellation and resource lifetimes. Remove
dead code and duplication introduced by the change. Comments explain non-obvious
invariants rather than restating mechanics. Never weaken safeguards or tests
to make a cleanup pass. Every nontrivial feature or bug fix needs meaningful
coverage; prefer real isolated components over mocking the thing under test.

Keep model/engine/protocol version identifiers, but avoid ticket/wave names in
files. Never commit binaries, credentials, `.external/` checkouts or local
runtime state. Preserve other contributors' changes in a dirty worktree.

## Releases And Production

Never release without an explicit request. Follow `docs/operations/provider-release.md`:
sign and notarize the canonical app, compute final hashes after signing, retain
regular-file verification artifacts and register the exact qualified release.
Do not bump a release version for an ordinary cleanup. Add user-visible changes
to a small topic-specific `Unreleased` changelog section without rewriting history.

Production mutations require specific human approval, including release/model
publication, credentials, infrastructure, hosting and traffic. No approval is
implied by a source change or successful test. Backend deployment belongs in
the sibling platform repository, not this checkout.

## Required Refactor Pass

After the first working version and focused validation, a dedicated refactor
subagent must review behavior-preserving cleanup before a PR is opened. Give it
the scope, diff, instructions, explicit file ownership, invariants and validation
commands. Do not edit its files concurrently. It must preserve tests and public
contracts, improve boundaries/names/control flow when warranted, and avoid
unrelated rewrites. A justified no-change assessment is valid.

Wait, inspect its changes, resolve regressions, and rerun affected checks plus
documentation validation. Report unavailable validation honestly. If subagents
are unavailable or delegation is prohibited, report the unresolved gate; a
self-review does not silently replace it. The coordinating parent owns this
gate when a narrowly scoped worker has been instructed not to delegate.

## Contributions And Pull Requests

Follow `.agents/skills/darkbloom-contributor/SKILL.md` and `CONTRIBUTING.md`.
Run docs-impact and docs lint before finalizing. A genuinely inapplicable mapping
requires the maintainer-applied `docs-not-needed` label, not a weakened checker.

Every PR commit must be signed and display Verified on GitHub, including fork
commits. Never commit, push, release or open a PR without authorization. Every
PR needs clearly labeled Before/After Mermaid diagrams covering observable
behavior and code flow; docs-only changes diagram navigation/ownership.
Include actual validation evidence, limitations and the refactor-pass outcome.

Stacks are linear: first PR targets `master`, each child its immediate parent.
Refresh parent-to-child with signed non-force merges. After each actual squash,
use `scripts/restack-after-squash.py ... --check`, then an authorized `--push`
according to `docs/developer/pull-requests.md`. Do not force-push, rewrite public
history, change merge policy or skip hooks without explicit approval. Recheck
signatures, CI, bases, approvals and mergeability after updates. None of this
authorizes merging a PR.
