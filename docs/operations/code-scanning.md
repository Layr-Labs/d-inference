# Code scanning (CodeQL)

Static analysis gate for the repo. Config: [`.github/workflows/codeql.yml`](../../.github/workflows/codeql.yml)
and [`.github/codeql/codeql-config.yml`](../../.github/codeql/codeql-config.yml).

## History

CodeQL ran via GitHub **default setup** (a UI toggle, no config in git) from
**2026-04-14** to **2026-06-16**, then was switched off. Nothing in the repo
recorded that it had ever been on, or that it stopped. Consequences:

- Two months of merges (Jun–Aug 2026) went unscanned.
- The Security tab kept serving the June snapshot — 12 open alerts — so the
  repo still *looked* scanned. For audit purposes this is worse than never
  having enabled it: it invites a reviewer to trust a stale result.
- Swift never worked under default setup. Every Swift analysis recorded
  `"unsuccessful execution", rules_count: 0` — autobuild could not build the
  package. Likely the reason the whole setup was abandoned.

Restored as advanced setup (config in git) in `ci/restore-codeql-gate`.

## What is scanned

| Language | Build mode | Trigger | Required check | Covers |
|---|---|---|---|---|
| `actions` | none | PR + push + weekly | yes | `.github/workflows/**` supply chain |
| `go` | autobuild | PR + push + weekly | yes | `coordinator/`, `e2e/` (one root module) |
| `javascript-typescript` | none | PR + push + weekly | yes | `console-ui/`, `admin-ui/`, `landing/` |
| `python` | none | PR + push + weekly | yes | `scripts/` harnesses |
| `rust` | none | PR + push + weekly | yes | `coordinator/promptsidecar` |
| `swift` | manual | **weekly + dispatch only** | no | `provider-swift/` |

`libs/*` submodules are excluded — vendored upstream MLX, not ours to fix.

### Why Swift is weekly and non-blocking

`provider-swift` is the highest-value target in the repo: it decrypts consumer
prompts and holds the Secure Enclave key. It is also the most expensive thing
to analyze — a cold build compiles the full Cmlx C++/Metal tree, ~20 min on a
paid `blacksmith-12vcpu-macos-latest` runner, and Swift extraction requires a
cold build (a warm `.build` produces an empty database, since extraction traces
real compiler invocations).

Per-PR Swift analysis would add ~30–45 min of macOS runner time to every PR and
reintroduce the exact failure that killed the June setup. A slow, occasionally
red required check is the most reliable way to get code scanning disabled again.
Weekly keeps the coverage; non-blocking keeps the pressure off.

**This is a real gap**: a Swift regression can merge on Monday and go unflagged
until the following Monday. Accepted deliberately. Revisit by making the build
reliable and cached-but-traceable first, then promote to per-PR.

## Why it can't be silently switched off again

Three layers, in order of strength:

1. **Config in git.** Advanced setup, not the UI toggle. Turning it off means a
   PR against `master`, which needs 1 approval, thread resolution, and signed
   commits (ruleset "Branch Rules"). It shows up in `git log`.
2. **Fail-closed required checks.** The five `analyze` jobs are required status
   checks on `master`. Delete the workflow and those contexts never report, so
   *nothing merges* until someone restores it or an admin edits the ruleset.
   This is why the workflow carries no `paths`/`paths-ignore` filters — a
   path-skipped job also never reports, which would deadlock every doc-only PR.
3. **Owner review on the config paths.** Required checks are fail-closed
   against deletion but not against a PR that keeps the job names while
   weakening coverage (dropping a matrix language, widening `paths-ignore`).
   `.github/CODEOWNERS` routes those paths to `@Layr-Labs/darkbloom`.

### Verifying the gate is live

```bash
# Advanced setup in use, default setup off:
gh api repos/Layr-Labs/d-inference/code-scanning/default-setup -q .state   # not-configured

# Most recent analysis per language on master — all should be recent:
gh api 'repos/Layr-Labs/d-inference/code-scanning/analyses?ref=refs/heads/master&per_page=20' \
  -q '.[] | "\(.created_at[0:10]) \(.category) results=\(.results_count) err=\(.error)"'

# Required contexts include the CodeQL jobs:
gh api repos/Layr-Labs/d-inference/rulesets/15055885 \
  -q '.rules[] | select(.type=="required_status_checks")
      | .parameters.required_status_checks[].context'
```

If the analyses query returns nothing newer than a week, the gate is broken
regardless of what the Security tab shows. That is the check to automate next.

## Alert backlog

12 alerts are open, frozen at the 2026-06-16 snapshot and **unverified against
current code**. Triage is deliberately out of scope of the re-enablement so the
first fresh run can re-baseline them.

| # | Severity | Rule | Location |
|---|---|---|---|
| 74 | high | `actions/untrusted-checkout/high` | `.github/workflows/codex.yml:59` |
| 69 | high | `go/disabled-certificate-check` | `coordinator/mdm/mdm.go:120` |
| 8, 9, 10 | high | `js/clear-text-storage-of-sensitive-data` | `console-ui/src/hooks/useAuth.ts:26,47,78` |
| ×7 | medium | `actions/missing-workflow-permissions` | `benchmarks`, `ci`, `claude`, `codex`, `integration` |

The 7 medium alerts are mechanical: five workflows have no top-level
`permissions:` block, so they inherit the repo default token scope.

## Maintenance

Actions are pinned by SHA. `.github/dependabot.yml` covers `gomod` and `npm`
but **not** `github-actions`, so `github/codeql-action` pins do not
auto-update. GitHub deprecates old `codeql-action` majors and eventually
hard-fails them; when that notice arrives, bump the two pinned SHAs in
`codeql.yml` together. Adding a `github-actions` dependabot ecosystem would
automate this at the cost of more PR volume.
