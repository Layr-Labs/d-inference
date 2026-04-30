# Contributing to Darkbloom (d-inference)

Thanks for your interest in contributing. Darkbloom is an experimental, build-in-public project — we welcome bug reports, feature ideas, docs improvements, and code contributions.

This guide covers what you need to know before opening an issue or PR.

## Ways to contribute

- **File a bug** — see [issue templates](https://github.com/Layr-Labs/d-inference/issues/new/choose).
- **Propose a feature** — open a feature request first so we can scope it together. Surprise PRs that touch protocol, billing, or attestation are likely to bounce.
- **Pick up a `good first issue`** — see the [open list](https://github.com/Layr-Labs/d-inference/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22). Comment on the issue to claim it before starting.
- **Improve docs** — small docs PRs are always welcome and don't need pre-discussion.
- **Report a vulnerability** — do **not** open a public issue. Use [GitHub Security Advisories](https://github.com/Layr-Labs/d-inference/security/advisories/new).

## Project tracking

- **[Roadmap board](https://github.com/orgs/Layr-Labs/projects/25)** — what's planned, in flight, and done. Filter by `Component` or `Priority`.
- **[Milestones](https://github.com/Layr-Labs/d-inference/milestones)** — what's targeted for each release (e.g. `v0.3.6`, `v0.4.0`). Every PR/issue should have a milestone if it's intended for a specific release.
- **Labels** — `area:*` for component, `bug` / `enhancement` / `security` for type, `good first issue` / `help wanted` for contributor guidance.

## Project layout

See [CLAUDE.md](CLAUDE.md) for the full layout and architectural decisions. The short version:

| Directory | Stack | What it is |
|-----------|-------|------------|
| `coordinator/` | Go | Central matchmaking server (runs on EigenCloud / GCP) |
| `provider/` | Rust | Hardened daemon on Apple Silicon Macs |
| `console-ui/` | Next.js 16 / React 19 | Web app (chat, billing, models) |
| `app/EigenInference/` | Swift / SwiftUI | macOS menu bar app for providers |
| `enclave/` | Swift | Secure Enclave attestation helper |
| `image-bridge/` | Python / FastAPI | Image generation backend adapter |

## Development setup

### Prerequisites

- macOS on Apple Silicon (M1+) for full provider/app development; the coordinator and console UI can be developed on any platform.
- Go 1.22+, Rust (stable), Node 20+, Python 3.11+, Swift 5.9+ (Xcode 15+).
- A working `git` config with `user.name` and `user.email`.

### First-time clone

```bash
git clone git@github.com:Layr-Labs/d-inference.git
cd d-inference
git config core.hooksPath .githooks   # enables pre-commit + pre-push checks
```

### Per-component build & test

```bash
# Coordinator
cd coordinator && go test ./...

# Provider
cd provider && PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test

# Console UI
cd console-ui && npm install && npm test && npx eslint src/

# macOS app
cd app/EigenInference && swift test

# Enclave helper
cd enclave && swift test

# Image bridge
cd image-bridge && python3 -m venv .venv && source .venv/bin/activate \
  && pip install -r requirements.txt pytest httpx && PYTHONPATH=. pytest
```

## Workflow

1. **Find or open an issue.** For non-trivial work, get rough alignment in the issue before writing code.
2. **Fork the repo** (external contributors) or **create a branch** (members) named `<type>/<short-slug>`, e.g. `fix/provider-restart-loop`, `feat/console-ui-billing-export`, `docs/contributing-guide`.
3. **Make your change.** Keep PRs focused — one logical change per PR. Avoid drive-by refactors.
4. **Add tests.** See "Testing" below.
5. **Run checks locally.** `git push` runs the pre-push hook which formats + builds + tests changed components.
6. **Open a PR** using the template. Fill in the test plan and link the issue with `Closes #N`.
7. **Set the milestone** if the change targets a specific release.
8. **Address review feedback** with new commits (don't force-push your branch while review is in flight — it makes review threads hard to follow).

## Testing

Every non-trivial change ships with tests. From `CLAUDE.md`:

- **Prefer live-isolated tests over mocks.** Real in-process servers, real test databases, real HTTP roundtrips. Mocks hide protocol drift.
- **Never point tests at production.** No live coordinator, no prod DB, no real wallets.
- **Cover both impls when a feature spans backends** (e.g. `store.Store` memory + postgres).
- **Test the real HTTP path.** Use `httptest.NewServer` for new endpoints.
- **Frontend features need frontend tests.** Vitest for components; for UI that can't be unit-tested, exercise it in a browser before declaring done.
- **Every bug fix gets a regression test** that fails without the fix.

## Code style

- **Go**: `gofmt` (enforced by the pre-commit hook).
- **Rust**: `cargo fmt` (enforced).
- **TypeScript**: ESLint clean (`npx eslint src/` from `console-ui/`).
- **Swift**: no enforced formatter; match the surrounding file.
- **Python**: PEP 8, 4-space indent, type hints encouraged.

Comments: explain *why*, not *what*. Don't add comments that just restate what the code does.

## Commit and PR conventions

- Use short, imperative commit subjects: `Add provider doctor check for SIP state`, not `Adding stuff`.
- One commit per logical change is ideal but not required.
- Don't include external IPs, internal hostnames, or secrets in code, comments, screenshots, or commit messages.

## Protocol changes

Several surfaces have to stay in sync. If you touch one, check the others:

- **WebSocket protocol**: `provider/src/protocol.rs` (Rust) ↔ `coordinator/internal/protocol/messages.go` (Go).
- **Provider bundle**: `scripts/build-bundle.sh`, `scripts/install.sh`, the Swift app launcher, and `LatestProviderVersion` in `coordinator/internal/api/server.go`.
- **Image generation**: coordinator consumer/provider handlers + provider proxying + `image-bridge/`.
- **Device linking**: coordinator device auth endpoints + provider `login`/`logout` commands.

The PR template will prompt you about this.

## Release cadence

Releases are cut by maintainers, not contributors. Don't bump versions or create tags in your PR — the release workflow handles that. If your change should land in a specific upcoming release, set the milestone on the PR.

See `CLAUDE.md` "Releases" for the full release procedure.

## Code of conduct

Be respectful. Disagree with ideas, not people. Maintainers reserve the right to remove comments, close issues, and block users that don't engage constructively.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
