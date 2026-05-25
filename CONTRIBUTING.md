# Contributing to Darkbloom

> Thank you for your interest in contributing. Darkbloom is an experimental, build-in-public project — we welcome bug reports, feature ideas, documentation improvements, and code contributions.

---

## Table of Contents

- [Ways to Contribute](#ways-to-contribute)
- [Project Tracking](#project-tracking)
- [Project Layout](#project-layout)
- [Development Setup](#development-setup)
- [Workflow](#workflow)
- [Testing](#testing)
- [Code Style](#code-style)
- [Commit & PR Conventions](#commit--pr-conventions)
- [Protocol Changes](#protocol-changes)
- [Release Cadence](#release-cadence)
- [Code of Conduct](#code-of-conduct)
- [License](#license)

---

## Ways to Contribute

| Contribution | How |
|-------------|-----|
| **File a bug** | Use the [issue templates](https://github.com/Layr-Labs/d-inference/issues/new/choose) |
| **Propose a feature** | Open a feature request first so we can scope it together. Surprise PRs that touch protocol, billing, or attestation are likely to bounce |
| **Pick up a `good first issue`** | See the [open list](https://github.com/Layr-Labs/d-inference/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22). Comment on the issue to claim it before starting |
| **Improve docs** | Small docs PRs are always welcome and don't need pre-discussion |
| **Report a vulnerability** | Do **not** open a public issue. Use [GitHub Security Advisories](https://github.com/Layr-Labs/d-inference/security/advisories/new) or email security@eigenlabs.org |

## Project Tracking

- **[Roadmap Board](https://github.com/orgs/Layr-Labs/projects/25)** — What's planned, in flight, and done. Filter by `Component` or `Priority`.
- **[Milestones](https://github.com/Layr-Labs/d-inference/milestones)** — What's targeted for each release (e.g. `v0.3.6`, `v0.4.0`). Every PR/issue should have a milestone if it's intended for a specific release.
- **Labels** — `area:*` for component, `bug` / `enhancement` / `security` for type, `good first issue` / `help wanted` for contributor guidance.

## Project Layout

For the full layout and architectural decisions, see [`CLAUDE.md`](CLAUDE.md).

| Directory | Stack | Description |
|-----------|-------|------------|
| `coordinator/` | Go | Central matchmaking server (runs on EigenCloud / GCP) |
| `provider/` | Rust | Hardened daemon on Apple Silicon Macs (legacy, retired at Swift cutover) |
| `provider-swift/` | Swift | CLI replacement for `provider/` (`darkbloom` + `darkbloom-enclave`) |
| `console-ui/` | Next.js 16 / React 19 | Web app (chat, billing, models) |
| `enclave/` | Swift | Secure Enclave helper + FFI bridge |
| `image-bridge/` | Python (FastAPI) | Image generation service |
| `scripts/` | Shell / Python | Build, signing, install, and deploy helpers |
| `docs/` | Markdown | Architecture, deploy runbooks, threat model |

## Development Setup

### Prerequisites

| Tool | Version | Required For |
|------|---------|-------------|
| Go | 1.22+ | Coordinator |
| Rust (stable) | Latest | Legacy provider |
| Swift | 5.9+ (Xcode 15+) | Swift provider, enclave, macOS app |
| Node.js | 20+ | Console UI |
| Python | 3.11+ | Image bridge, crypto interop tests |
| Git | — | Working `user.name` and `user.email` config required |

> **Note:** macOS on Apple Silicon (M1+) is required for full provider/app development. The coordinator and console UI can be developed on any platform.

### First-Time Clone

```bash
git clone git@github.com:Layr-Labs/d-inference.git
cd d-inference
git config core.hooksPath .githooks   # Enables pre-commit + pre-push checks
```

### Build & Test

```bash
# Coordinator
cd coordinator && go test ./...

# Legacy Rust provider
cd provider && PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test

# Swift provider (CLI replacement)
cd provider-swift && swift test

# Console UI
cd console-ui && npm install && npm test && npx eslint src/

# Cross-language NaCl box parity test (PyNaCl <-> Rust crypto_box <-> Swift libsodium)
python3 -m pytest tests/test_crypto_interop.py
```

## Workflow

1. **Find or open an issue.** For non-trivial work, get rough alignment in the issue before writing code.
2. **Fork the repo** (external contributors) or **create a branch** (members) named `<type>/<short-slug>`:
   - `fix/provider-restart-loop`
   - `feat/console-ui-billing-export`
   - `docs/contributing-guide`
3. **Make your change.** Keep PRs focused — one logical change per PR. Avoid drive-by refactors.
4. **Add tests.** See [Testing](#testing) below.
5. **Run checks locally.** `git push` runs the pre-push hook which formats, builds, and tests changed components.
6. **Open a PR** using the template. Fill in the test plan and link the issue with `Closes #N`.
7. **Set the milestone** if the change targets a specific release.
8. **Address review feedback** with new commits (don't force-push your branch while review is in flight — it makes review threads hard to follow).

## Testing

Every non-trivial change ships with tests.

| Principle | Details |
|-----------|---------|
| **Live-isolated over mocks** | Real in-process servers, real test databases, real HTTP roundtrips. Mocks hide protocol drift. |
| **Never point tests at production** | No live coordinator, no prod DB, no real wallets. |
| **Cover both impls** | When a feature spans backends (e.g. `store.Store` memory + postgres), test both. |
| **Test the real HTTP path** | Use `httptest.NewServer` for new endpoints. |
| **Frontend features need frontend tests** | Vitest for components; for UI that can't be unit-tested, exercise it in a browser before declaring done. |
| **Every bug fix gets a regression test** | It must fail without the fix and pass with it. |

## Code Style

| Language | Formatter | Enforcement |
|----------|-----------|-------------|
| Go | `gofmt` | Pre-commit hook |
| Rust | `cargo fmt` | Pre-commit hook |
| TypeScript | ESLint | `npx eslint src/` from `console-ui/` |
| Swift | — | No enforced formatter; match the surrounding file |
| Python | PEP 8 | 4-space indent, type hints encouraged |

Comments: explain *why*, not *what*. Don't add comments that just restate what the code does.

## Commit & PR Conventions

- Use **short, imperative** commit subjects: `Add provider doctor check for SIP state`, not `Adding stuff`.
- One commit per logical change is ideal but not required.
- Don't include external IPs, internal hostnames, or secrets in code, comments, screenshots, or commit messages.

## Protocol Changes

Several surfaces must stay in sync. If you touch one, check the others:

| Surface | Files |
|---------|-------|
| **WebSocket protocol** | `provider/src/protocol.rs` (Rust) ↔ `coordinator/protocol/messages.go` (Go) |
| **Provider bundle** | `.github/workflows/release-swift.yml`, `scripts/install.sh`, and `LatestProviderVersion` in `coordinator/api/server.go` |
| **Image generation** | Coordinator consumer/provider handlers route to the standalone image-generation service; `provider-swift` does not handle images |
| **Device linking** | Coordinator device auth endpoints + provider `login`/`logout` commands |

The PR template will prompt you about these sync points.

## Release Cadence

Releases are cut by maintainers, not contributors. Don't bump versions or create tags in your PR — the release workflow handles that. If your change should land in a specific upcoming release, set the milestone on the PR.

See [`CLAUDE.md`](CLAUDE.md) "Releases" for the full release procedure.

## Code of Conduct

Be respectful. Disagree with ideas, not people. Maintainers reserve the right to remove comments, close issues, and block users that don't engage constructively.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
