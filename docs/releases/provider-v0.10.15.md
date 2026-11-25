<!--
> Last updated: 2026-11-18

The GitHub release notes of provider v0.10.15 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Darkbloom provider 0.10.15 hardens the provider's security checks, lets your own requests wait for a busy Mac instead of failing, makes pairs you run yourself steadier, opens longer requests and long videos on GLM-5.3-Flash, speeds up Gemma 4, and has Nemotron 3.5 Super hand back network requests it can't start in time, so another Mac can serve them. Update with `darkbloom update`.

## Highlights

### Security

- Every Darkbloom program now hardens itself as it starts, before it creates a key, reads a request or loads a model,
  and a Mac where that fails doesn't serve. `darkbloom doctor` shows it as a new `startup hardening` check.
- Darkbloom now serves network traffic only as its background service. `darkbloom start --foreground` no longer serves
  network traffic: start the service with `darkbloom start` (`darkbloom start --local --here` still serves this Mac
  only, in a terminal). The check is stronger on macOS 15.4 and later.
- Release builds connect to Darkbloom's coordinator only over an encrypted connection: a coordinator address that would
  connect without TLS is refused with a message saying how to fix it. The default and any `wss://` or `https://` address
  keep working.
- The SSD prefix cache starts over once with a newly created key, and the earlier key is removed. Cached prompt prefixes
  are rebuilt, so the first requests after the update may take a little longer to start.
- A two-Mac pair now starts only helper processes signed like Darkbloom itself, and checks them again before sending
  them anything. If a helper doesn't match, the pair doesn't start and `darkbloom doctor` says what to fix.
- Developer-only cluster settings have no effect in release builds.
- Your Mac now serves Darkbloom requests only with System Integrity Protection fully on (Apple's default) and Secure
  Boot at Full Security, checked on the Mac itself as well as by Apple's attestation. If a protection is off, `darkbloom
  start` says which one and how to turn it back on in Recovery, and `darkbloom doctor` and `darkbloom status` show it.
  Serving only yourself (`darkbloom start --local`) is unaffected.

### Your own Mac and pair

- Requests on your own local API (one Mac, `darkbloom start --local`, a two-Mac pair's leading Mac, `cluster local`)
  that can't start because other requests hold the memory now wait their turn for as long as it takes, instead of
  failing at once; only a request that can't fit even on an idle Mac is asked to be smaller. Agents such as Hermes no longer take a busy Mac for a
  conversation that's too long.
- On a two-Mac pair you run yourself, a short request sent while a long prompt is being read no longer fails after
  about ten seconds: your own requests are bounded only by their own deadline.
- If one of your own requests reaches its overall time limit, it now gets a clear "this Mac is busy, retry in a moment"
  answer (HTTP 503 with `Retry-After`), or that message as its last event when streaming, instead of "Response
  generation failed".
- A two-Mac pair whose share one Mac's memory check refuses, because other apps hold the memory, now chooses a split
  that fits that Mac's free memory instead of trying the same split again every 30 seconds without serving. Restarts of
  the refused part also slow down, up to five minutes apart.

### GLM-5.3-Flash

- On a two-Mac GLM-5.3-Flash pair that splits the model's layers, your own requests can now use up to 262,144 tokens, as
  each Mac's memory allows, instead of 32,768 in and 32,768 out. Darkbloom requests keep their present limits.
- A Mac serving GLM-5.3-Flash on its own now answers about a long video (past about a minute and a half at 720p, or 43
  seconds at 1080p, up to the 10-minute limit) from frames spread across the whole clip, instead of refusing it. Shorter
  clips are unchanged, and two-Mac GLM pairs still refuse such clips for now.

### Gemma 4

- Gemma 4 26B generates a single request a little faster (about 2 % on an M5 Ultra), with exactly the same output as
  before.

### Nemotron 3.5 Super

- A Mac serving Nemotron 3.5 Super now turns down at once a network request whose first output it can't deliver in
  time, judged by its own recent speed, instead of holding it until the time runs out. Darkbloom then gives the request
  to another Mac with almost all of its time left. Your own requests have no such time limit and are never turned down
  this way.

### Updates and releases

- When `darkbloom update` fails on a nearly full disk, it now says how much space is free and how much the update needs
  (0.10.14's message didn't show when the CLI ran through its usual link).
- Release publishing tolerates slow downloads of the signed build, and the release page shows these notes.

## Upgrade notes

- **Pairs:** both Macs of a pair must run the same version. A pair on 0.10.14 updates itself, and a pair that serves
  only you comes back by itself after `darkbloom update` on both Macs. `darkbloom update --rollback` puts back 0.10.14.
- **`darkbloom start --foreground` no longer serves network traffic:** if you ran network serving that way (in a
  terminal, tmux or your own supervisor), start the background service with `darkbloom start` instead.
- **Boot security:** a Mac with System Integrity Protection partly off, or with Reduced or Permissive Security, stops
  serving Darkbloom requests after the update; `darkbloom doctor` says what to change in Recovery.
- The security stack is as in 0.10.14 (end-to-end encryption, attestation, signing and weight hashes), with the
  stricter checks above.

## For operators: turning a change off

Set the variable before `darkbloom start` (or `darkbloom cluster`); the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS=120` (or `0`) | Your own requests wait at most two minutes for memory (or are refused at once when the Mac is busy, as in 0.10.14) |
| `DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0` | A pair's own requests keep the first-token allowance, as in 0.10.14 |
| `DARKBLOOM_NEMOTRON_SUPER_FIRST_CONTENT_REFUSAL=0` | Nemotron 3.5 Super starts every network request, as in 0.10.14 |
| `DARKBLOOM_CLUSTER_MEMORY_REFUSAL_REPLAN=0` (export it for every `darkbloom cluster` run) | A pair re-plans after a memory refusal as in 0.10.14 |
| `DARKBLOOM_GLM_LONG_VIDEO_SAMPLING=0` | GLM-5.3-Flash refuses a video past its frame limit, as in 0.10.14 |
| `DARKBLOOM_GEMMA4_MTP_COMMAND_BUFFERS=0` | Gemma 4's multi-token prediction submits GPU work as in 0.10.14 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.15/CHANGELOG.md).
