# Contributing To Darkbloom Provider

Contribute provider-local Swift/native code, model support, landing improvements,
tests and documentation here. Read [AGENTS.md](AGENTS.md) and
[documentation rules](docs/AGENTS.md) before changing ownership-sensitive files.

## Choose The Repository

Keep sibling checkouts at `Darkbloom/d-inference` and
`Darkbloom/darkbloom-platform`. Never nest them. For a new workspace:

```bash
git clone --recurse-submodules https://github.com/Layr-Labs/d-inference.git Darkbloom/d-inference
git clone https://github.com/Layr-Labs/darkbloom-platform.git Darkbloom/darkbloom-platform
```

The coordinator/backend, Rust prompt sidecar, consumer console and internal admin
development belongs exclusively in the platform repository. Never implement,
commit, push or upload new backend, console or admin code here. Device-local
Swift HTTP APIs are provider code, not the centralized backend. Check your
remote, branch and intended diff before editing or pushing. See the
[owner map](docs/developer/navigation.md).

The latest coordinator source is the default branch of
https://github.com/Layr-Labs/darkbloom-platform. For coordinator diagnosis, agents
must fetch that branch and read its `AGENTS.md` and the actual relevant code.
Old d-inference copies and pinned documentation are historical references, not
the latest implementation.

## Develop And Test

Install tools with `mise install`, initialize recursive submodules, and follow
[build](docs/developer/build.md) and [test](docs/developer/test.md).

```bash
make provider-build
make provider-test
make landing
make docs-impact-check BASE=origin/master
make docs-check
```

Run only the checks appropriate to your change. Never use production services,
credentials or live provider state as test fixtures. New nontrivial behavior and
bug fixes need meaningful regression coverage. Retain native resource, memory,
privacy and cancellation safeguards; do not replace actual execution evidence
with fixture hashes. Public golden vectors and private platform qualification
are separate checks.

## Code And Review

Follow the clean-code, modularity, native safety and independent refactor-pass
requirements in [AGENTS.md](AGENTS.md). Keep public contracts stable, helpers
cohesive, errors actionable and resource ownership explicit. Swift has no
repository-enforced formatter. Landing uses its own ESLint configuration.
Do not include generated binaries, secrets or unrelated changes.

Protocol, telemetry, model-manifest, memory-quotation and installer changes
require coordinated platform review. Review exact revisions and preserve enum
casing and optional fields. Do not copy private implementation into public
fixtures or run a moving platform checkout from provider CI.

## Commits And PRs

Use a focused branch and concise descriptive commits. Every PR commit must be
signed and Verified on GitHub. Inspect status, diff and recent history before an
authorized commit; stage only intended files. Do not force-push or rewrite
published history. Follow the [stacking guide](docs/developer/pull-requests.md)
for signed parent updates and post-squash ancestry repair.

Every PR includes Before/After Mermaid diagrams showing behavior and code flow
(navigation/ownership for docs), concrete checks and their outcomes, known
limitations, and an independent refactor-pass result. Keep draft status while
required checks or operational gates remain unresolved. Do not claim deployment,
release, native parity or full-model qualification from a source cleanup.

### Changelog entries with less merge contention

Ordinary PRs add one uniquely named Markdown file under
[`changelog.d/`](changelog.d/README.md); they do **not** edit or regenerate
[`CHANGELOG.md`](CHANGELOG.md). Different files remove the shared insertion
point that made unrelated PRs conflict. Fragments do not replace the canonical
documentation required by [`docs/AGENTS.md`](docs/AGENTS.md).

1. Choose a descriptive kebab-case name, optionally prefixed with the issue or
   PR number, such as `1402-coordinator-env-retirement.md`. Start with
   `### Coordinator environment retirement`, a blank line, and concise bullets
   describing observable changes and limitations. Do not put release versions
   or dates in the fragment.
2. Keep follow-up edits in that PR's fragment. Do not edit another PR's pending
   notes, split one change across several files, or use a shared `unreleased.md`.
   Run `make changelog-check` and `make changelog-preview` before review.
3. For an open PR based on the old workflow, preserve current `master` history
   when merging it. Move only that PR's not-yet-released notes into a new
   fragment and remove its duplicate root-changelog insertion. Never silently
   drop another change or assign a version solely because a PR was merged.
4. Release preparation alone renders selected fragments with
   `python3 scripts/changelog.py render --version X.Y.Z --date YYYY-MM-DD NAME.md ...`.
   Review the output, insert it above the previous release, and remove exactly
   those fragment files in the same commit. Omitting the names selects all
   pending fragments, so first verify that every one belongs in the candidate.
   The renderer is read-only and refuses an already recorded version.
5. Record actual publication separately from source preparation. Verify the
   annotated tag and published release before claiming shipment; coordinator,
   console, model activation and physical qualification remain independent.
   Publication failure leaves a prepared candidate, not a shipped release.

Do not configure a union merge driver for the changelog. Combining conflicting
lines without understanding versions can silently duplicate notes or put a
change under the wrong release. Existing published sections are historical;
correct them only with source/tag evidence and explicit authorization.

## Release And Publication

Follow [provider release](docs/operations/provider-release.md) and
[model publication](docs/operations/model-migration.md). External registration
APIs remain supported; backend build/test/deploy does not live here. Release,
model publication, infrastructure, hosting and traffic changes require specific
human approval. Never modify live endpoints or credentials as incidental cleanup.

## License

Contributions are covered by [LICENSE](LICENSE). Keep required attribution and
third-party notices intact. Be respectful, factual and constructive in review.
