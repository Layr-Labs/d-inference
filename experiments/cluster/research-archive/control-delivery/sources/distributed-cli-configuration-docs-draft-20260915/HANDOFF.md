# Experimental distributed CLI documentation

This private proposal changes only `docs/provider/cli-reference.md`,
`docs/reference/configuration.md` and `CHANGELOG.md`. MAIN is untouched.

`documentation.patch` applies to the exact three originals in `base-pins.json`.
It documents explicit local startup, per-member saved setup, the default-provider
reference requirement, the authenticated worker-owner entry, current 9B greedy
MTP-off limits and retained failure/quarantine behavior. The new changelog entry
is explicitly unreleased; the text does not claim live product qualification.

The two reference pages keep the existing freshness-stamp format and are
restamped for the reviewed MAIN commit. `source-pins.json` identifies the 23
actual MAIN sources read for this proposal. `checks.json` records exact-base,
patch, added-link/anchor and source-path checks. No runtime, native, model or
network execution was performed. Root owns promotion and full repository
`docs-check` afterward.

No general docs cleanup, release version changes or design-body edits are included.
