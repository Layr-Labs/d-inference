# Contributing to Darkbloom (d-inference)

Thanks for your interest in contributing. Darkbloom is an experimental, build-in-public project — we welcome bug reports, feature ideas, docs improvements, and code contributions.

This guide covers what you need to know before opening an issue or PR.

## Ways to contribute

- **File a bug** — see [issue templates](https://github.com/Layr-Labs/d-inference/issues/new/choose).
- **Propose a feature** — open a feature request first so we can scope it together. Surprise PRs that touch protocol, billing, or attestation are likely to bounce.
- **Pick up a `good first issue`** — see the [open list](https://github.com/Layr-Labs/d-inference/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22). Comment on the issue to claim it before starting.
- **Improve docs** — small docs PRs are always welcome and don't need pre-discussion. Read [`docs/AGENTS.md`](docs/AGENTS.md) first (page types, freshness stamps, `make docs-check`).
- **Report a vulnerability** — do **not** open a public issue. Use [GitHub Security Advisories](https://github.com/Layr-Labs/d-inference/security/advisories/new).

## Project tracking

- **[Roadmap board](https://github.com/orgs/Layr-Labs/projects/25)** — what's planned, in flight, and done. Filter by `Component` or `Priority`.
- **[Milestones](https://github.com/Layr-Labs/d-inference/milestones)** — what's targeted for each release (e.g. `v0.3.6`, `v0.4.0`). Every PR/issue should have a milestone if it's intended for a specific release.
- **Labels** — `area:*` for component, `bug` / `enhancement` / `security` for type, `good first issue` / `help wanted` for contributor guidance.

## Project layout

The full map is [`docs/architecture/overview.md`](docs/architecture/overview.md); the build-oriented layout is in [`docs/developer/build.md`](docs/developer/build.md). The short version:

| Directory | Stack | What it is |
|-----------|-------|------------|
| `coordinator/` | Go (single root module `github.com/eigeninference/d-inference`) | Central matchmaking server; production and dev run on separate GCP projects |
| `coordinator/promptsidecar/` | Rust | Prompt-contract sidecar, built as a static musl binary into the coordinator image |
| `provider-swift/` | Swift | Hardened CLI daemon on Apple Silicon Macs (`darkbloom` + `darkbloom-enclave`) |
| `console-ui/`, `admin-ui/` | Next.js 16 / React 19 | Consumer web app (chat, billing, models) and the operator console |
| `landing/` | Next.js 16 / React 19 | Marketing site; `make landing` installs, lints, builds and tests |
| `e2e/` | Go | End-to-end suite that drives a real coordinator and provider |
| `deploy/`, `scripts/` | Cloud Build, shell | GCP deployment and operator tooling |
| `libs/` | git submodules | `mlx-swift`, `mlx-swift-lm`, `mlx` |
| `docs/` | Markdown | Linted by `make docs-check`; rules in [`docs/AGENTS.md`](docs/AGENTS.md) |

## Development setup

### Prerequisites

- macOS on Apple Silicon for anything under `provider-swift/`; the coordinator, sidecar, e2e suite, and UIs build on macOS or Linux.
- Toolchains are pinned in [`mise.toml`](mise.toml) and installed with `mise install`: Go `1.25.0`, Rust `1.88.0`, Node `22`, Swift `6.3`, Python `3.12`, plus `jq`, `gh`, `awscli`, `gcloud`. Xcode Command Line Tools and `cmake` are needed for the provider's metallib.
- A working `git` config with `user.name` and `user.email`.

### First-time clone

```bash
git clone --recurse-submodules git@github.com:Layr-Labs/d-inference.git
cd d-inference
mise install
git config core.hooksPath .githooks   # enables pre-commit + pre-push checks
```

### Per-component build & test

`make help` lists every target. The ones you will use most:

```bash
make coordinator-test        # runner guards + mirrored Go suites with isolated API shards
make prompt-sidecar          # cargo fmt --check, clippy -D warnings, test, release build
make provider-test           # swift build + swift test with a source-matched mlx.metallib (Apple Silicon)
make ui-lint ui-test         # eslint + vitest for console-ui
make docs-check              # freshness stamps, links, cited paths, orphans
make test                    # everything CI runs as unit tests
```

Details, including the Swift nested test suites, the e2e suite, and the CI workflow map, are in [`docs/developer/build.md`](docs/developer/build.md) and [`docs/developer/test.md`](docs/developer/test.md).

## Workflow

1. **Find or open an issue.** For non-trivial work, get rough alignment in the issue before writing code.
2. **Fork the repo** (external contributors) or **create a branch** (members) named `<type>/<short-slug>`, e.g. `fix/provider-restart-loop`, `feat/console-ui-billing-export`, `docs/contributing-guide`.
3. **Make your change.** Keep PRs focused — one logical change per PR. Avoid drive-by refactors.
4. **Add tests.** See "Testing" below.
5. **Run checks locally.** `git push` runs [`.githooks/pre-push`](.githooks/pre-push): `gofmt` + `go test` when `coordinator/` changed, `eslint` + `next build` when `console-ui/` changed. Swift, Rust, and docs checks run in CI (`make test` runs them locally).
6. **Open a PR** using the template. Fill in the test plan and link the issue with `Closes #N`.
7. **Set the milestone** if the change targets a specific release.
8. **Address review feedback** with new commits (don't force-push your branch while review is in flight — it makes review threads hard to follow).

## Testing

Every non-trivial change ships with tests. How to run each suite is in [`docs/developer/test.md`](docs/developer/test.md). The rules:

- **Prefer live-isolated tests over mocks.** Real in-process servers, real test databases, real HTTP roundtrips. Mocks hide protocol drift.
- **Never point tests at production.** No live coordinator, no prod DB, no real wallets.
- **Cover both impls when a feature spans backends** (e.g. `store.Store` memory + postgres).
- **Test the real HTTP path.** Use `httptest.NewServer` for new endpoints.
- **Frontend features need frontend tests.** Vitest for components; for UI that can't be unit-tested, exercise it in a browser before declaring done.
- **Every bug fix gets a regression test** that fails without the fix.
- **Keep coordinator tests separate.** Every coordinator `_test.go` belongs in
  `coordinator/tests/`, mirrored by production owner. Public HTTP/WS contracts
  use `tests/api/<domain>/contracts/`; shared fixtures use `tests/internal/`.
  Extract genuine production-consumed components or retain injected collaborators
  when testing private invariants across packages; do not export maps/locks,
  add test-only production facades, copy implementations or use overlays.
  `go test ./coordinator/...` discovers all suites; a focused production package
  selector does not substitute for its mirrored test selector.

## Code style

- **Go**: `gofmt` (enforced by the pre-commit hook); `golangci-lint` in CI.
- **Rust**: `cargo fmt --all -- --check` and `cargo clippy --locked --all-targets -- -D warnings` (`make prompt-sidecar-format prompt-sidecar-check`).
- **TypeScript**: ESLint clean (`npx eslint src/` from `console-ui/` or `admin-ui/`).
- **Swift**: no enforced formatter; match the surrounding file.
- **Python**: PEP 8, 4-space indent, type hints encouraged.
- **Docs**: `make docs-check` must pass; every page under `docs/` carries a freshness stamp (`make docs-stamp FILES=docs/path.md`).

Comments: explain *why*, not *what*. Don't add comments that just restate what the code does.

## Commit and PR conventions

- Use short, imperative commit subjects: `Add provider doctor check for SIP state`, not `Adding stuff`.
- One commit per logical change is ideal but not required.
- Don't include external IPs, internal hostnames, or secrets in code, comments, screenshots, or commit messages.

## Protocol changes

Several surfaces have to stay in sync. If you touch one, check the others:

- **WebSocket protocol**: `provider-swift/Sources/ProviderCore/Protocol/Messages.swift` (Swift) ↔ `coordinator/protocol/messages.go` (Go) ↔ [`docs/reference/protocol-messages.md`](docs/reference/protocol-messages.md).
- **Provider bundle**: `.github/workflows/release-swift.yml`, canonical
  `scripts/install.sh`, its generated embed at `coordinator/api/install.sh`
  (kept identical by `scripts/sync-install-embed.sh`), and the version pair
  `ProviderCore.version` ↔ `LatestProviderVersion` in `coordinator/api/server.go`
  (checked by `scripts/check-release-version.sh`).
- **Device linking**: coordinator device auth endpoints + provider `login`/`logout` commands.
- **Docs**: the table in [`docs/AGENTS.md`](docs/AGENTS.md) ("When you change code, change these docs") maps each kind of code change to the page that must move in the same PR.

The PR template will prompt you about this.

## Release cadence

Releases are cut by maintainers, not contributors. Don't bump versions or create tags in an ordinary PR. Maintainers prepare the version constants and changelog, then tag the reviewed source for the release workflow. If your change should land in a specific upcoming release, set the milestone on the PR.

The release runbook is [`docs/operations/provider-release.md`](docs/operations/provider-release.md); production coordinator deploys are [`docs/operations/coordinator-deploy.md`](docs/operations/coordinator-deploy.md).

### Changelog entries with less merge contention

User-visible changes need an entry in the root [`CHANGELOG.md`](CHANGELOG.md).
Keep the entry in the same PR as the change; it does not replace the canonical
documentation required by [`docs/AGENTS.md`](docs/AGENTS.md).

1. Read the target branch's current changelog before editing. For an ordinary
   PR, add a small, self-contained section near the top using the existing
   `## Unreleased — <topic>` style. Describe observable changes and important
   limitations, not a commit-by-commit implementation log.
2. Keep review updates inside your topic's section. Do not keep moving it back
   to the top as other PRs land, rename a shared `Unreleased` heading for your
   feature, or reorder, rewrap or clean up unrelated entries. Extend an existing
   topic only when your change actually belongs to it.
3. Leave version assignment, release dates and consolidation to an explicitly
   requested release-preparation change. A current version constant or an
   unshipped release-candidate heading is not a reason to add an ordinary PR
   to that release. Do not change shipped history or claim publication from a
   source merge or version bump.
4. When updating your branch, resolve changelog conflicts by preserving the
   target branch's entries and your topic's intended changes. Do not take the
   whole file from either side. If release preparation has moved your topic,
   check the new release boundary rather than duplicating it or putting new
   work into an already shipped section.
5. Review the final changelog diff against the current target branch, not just
   the last commit: unrelated entries must remain intact and your change must
   appear once. Run `git diff --check` and the documentation checks before
   requesting review.

Small topic-local edits reduce contention and make resolution easier; they do
not eliminate conflicts when parallel PRs insert at the same location. Keep
the existing single-file changelog rather than introducing per-PR fragments
or a new release-generation process for an ordinary contribution.

## Code of conduct

Be respectful. Disagree with ideas, not people. Maintainers reserve the right to remove comments, close issues, and block users that don't engage constructively.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
