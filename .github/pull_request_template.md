<!--
Thanks for contributing to d-inference. A few quick notes:

- Link an issue with `Closes #123` so the issue auto-closes on merge.
- Keep backend changes in darkbloom-platform; this repository owns provider/native and landing code.
- Add `area:*` labels for the components you touched.
- Don't include external IPs, internal hostnames, or secrets in code, comments, or screenshots.
-->

## Summary

<!-- 1–3 sentences. What changed and why. -->

## Linked issue

Closes #

## Test plan

<!--
A bulleted checklist of how you verified this. Include the specific commands you ran.
For UI changes, include a screenshot or short video.
-->

- [ ]
- [ ]

## Components touched

<!-- Tick all that apply so reviewers know what to look at. -->

- [ ] provider-swift (Swift CLI)
- [ ] native runtime / MLX
- [ ] landing (Next.js)
- [ ] enclave (Swift)
- [ ] CI / provider release
- [ ] docs

## Protocol / interface changes

<!--
If you changed a WebSocket message, an HTTP endpoint, a config key, or a CLI flag:
- Did you preserve public fixtures and coordinate external platform contract changes without fetching private source in PR CI?
- Are release artifacts (`release-swift.yml`, `scripts/install.sh`, `ProviderCore.version`) still consistent?
- Does this need a version bump or a migration note?
-->

- [ ] No protocol/interface changes
- [ ] Yes — described above and matching side updated

## Documentation impact

<!--
Use docs/AGENTS.md section 7 to identify the canonical documentation for this
change. CI checks documentation-sensitive source paths. If no documentation
applies, explain why and ask a maintainer to apply the docs-not-needed label.
-->

- [ ] Canonical documentation updated
- [ ] No documentation needed — reason:

## Notes for reviewers

<!-- Anything non-obvious: tradeoffs taken, edge cases not covered, follow-ups planned. -->

## Before And After

<!-- Include labeled Mermaid diagrams covering behavior and code flow. -->

## Refactor Pass

<!-- Record the dedicated refactor review outcome and final focused validation. -->
