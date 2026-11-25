<!--
> Last updated: 2026-11-19

The GitHub release notes of provider v0.10.16 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Bug fixes, performance and security posture improvements. Update with `darkbloom update`.

## Upgrade notes

- **Pairs:** both Macs of a pair must run the same version; a pair on 0.10.15 updates itself. `darkbloom update
  --rollback` puts back 0.10.15.
- **Fan control:** if you use Darkbloom's fan control, run `sudo darkbloom fan enable` once after the update to update
  the fan helper (your settings stay); the older helper keeps working until then.

## For operators: turning a change off

Set the variable before `darkbloom start`; the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR=off` | GPT-OSS samples tool calls without the schema grammar, as in 0.10.15 |
| `DARKBLOOM_QWEN35_DECODE_COMMAND_BUFFERS=0` | Qwen 3.5-family decoding submits GPU work as in 0.10.15 |
| `DARKBLOOM_MTP_PENALTY_ROWS=0` | Qwen 3.5 / 3.6 rows with a presence or frequency penalty decode without speculation, as in 0.10.15 |
| `DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD_SORTED=0` | Gemma 4 26B's feed-forward path for 8–16 decode rows as in 0.10.15 |
| `DARKBLOOM_GEMMA_MTP_LONE_ROW=0` | Gemma 4 26B speculates with several requests, as in 0.10.15 |
| `DARKBLOOM_QWEN38_PREFILL_CHUNK=0` | Qwen 3.8 27B on M5 Ultra prefills in 512-token steps while other requests generate, as in 0.10.15 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.16/CHANGELOG.md).
