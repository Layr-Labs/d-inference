<!--
> Last updated: 2026-11-20

The GitHub release notes of provider v0.10.17 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Bug fixes, performance and security posture improvements. Update with `darkbloom update`.

## Upgrade notes

- **Pairs:** both Macs of a pair must run the same version; a pair on 0.10.16 updates itself. `darkbloom update
  --rollback` puts back 0.10.16.
- **Serving holds:** if authenticated root is disabled or the provider runs inside a sandbox it didn't set up, the Mac
  serves only its owner's requests until that's restored.
- **State files:** release builds keep their state files in the install directory; the variables that used to move them
  (`DARKBLOOM_STATE_FILE` and the others in the changelog) apply to development builds only.

## For operators: turning a change off

Set the variable before `darkbloom start`; the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER=0` | a pair whose start was stopped too early waits for `darkbloom cluster recover`, as in 0.10.16 |
| `DARKBLOOM_CLUSTER_UPDATE_REPLAN_GUARD=0` | a pair's update check runs while its update restarts, as in 0.10.16 |
| `DARKBLOOM_HARMONY_AUTO_TOOL_WIDEN=off` | GPT-OSS automatic tool calls read Pydantic and zod schemas as in 0.10.16 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.17/CHANGELOG.md).
