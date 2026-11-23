<!--
> Last updated: 2026-11-23

The GitHub release notes of provider v0.10.18 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Bug fixes, performance and security posture improvements. Update with `darkbloom update`.

## Upgrade notes

- **Pairs:** both Macs of a pair must run the same version; a pair on 0.10.17 updates itself. `darkbloom update
  --rollback` puts back 0.10.17.

## For operators: turning a change off

Set the variable before `darkbloom start`; the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_GLM_REFERENCE_TOOL_HISTORY=0` | GLM-5.3-Flash refuses the tool-history and schema shapes it refused in 0.10.17 |
| `DARKBLOOM_GLM_SHARED_GRANT_WAIT=0` | a local GLM request that fits only once another loaded model gives back memory is refused at once, with 0.10.17's busy words |
| `DARKBLOOM_MEDIA_ON_EVERY_ROLE=0` | images and video outside user messages are handled as in 0.10.17 |
| `DARKBLOOM_MTP_STOP_STRING_ROWS=0` | Gemma 4 26B requests with stop strings decode without speculation, as in 0.10.17 |
| `DARKBLOOM_MTP_PENALTY_ROWS=0` | Gemma 4 26B requests with a presence or frequency penalty decode without speculation, as in 0.10.17 |
| `DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW=0` | Gemma 4 26B on M5 Ultra drafts two tokens with one or two requests decoding, as in 0.10.17 |
| `DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT=0` | Gemma 4 26B prefix-cache checkpoints use 0.10.17's layout before the draft model attaches |
| `DARKBLOOM_CLUSTER_LEADERSHIP_WINDOW_WAIT=0` | cluster commands wait a fixed 40 s for this Mac's leadership, as in 0.10.17 |
| `DARKBLOOM_CLUSTER_STOP_ALONE_UNCONFIRMED=0` | `cluster stop --service` on a leading Mac whose partner doesn't answer refuses, as in 0.10.17 |
| `DARKBLOOM_TTFT_MEDIA_PREP_STREAM=0` | Qwen 3.5, 3.6 and 3.8 image and video preparation shares the running requests' GPU stream, as in 0.10.17 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.18/CHANGELOG.md).
