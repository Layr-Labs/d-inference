<!--
> Last updated: 2026-11-25

The GitHub release notes of provider v0.10.19 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Inkling 2 Mini fixes and a startup fix. Update with `darkbloom update`.

## Upgrade notes

- Inkling 2 Mini: log probabilities cover only the answer when thinking is off, hidden thinking no longer counts as
  reasoning tokens, and a request can require a tool call. darkbloom start keeps serving when one Autopilot model is
  still downloading.
- **Pairs:** both Macs of a pair must run the same version; a pair on 0.10.18 updates itself. `darkbloom update
  --rollback` puts back 0.10.18. If you roll one Mac of a pair back to an earlier version and then forward again,
  `darkbloom cluster` may report that the saved pair approval differs. If it does, approve the pair again.

## For operators: turning a change off

Set the variable before `darkbloom start`; the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_INKLING_FORCED_TOOLS=0` | Inkling 2 Mini requests with `tool_choice` `required` or a named function are prompt-forced only, as in 0.10.18 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.19/CHANGELOG.md).
