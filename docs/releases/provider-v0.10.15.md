<!--
> Last updated: 2026-11-17

The GitHub release notes of provider v0.10.15 (scripts/provider_release_notes.py publishes this file).
This comment holds the docs freshness stamp; GitHub does not show it.
-->

Darkbloom provider 0.10.15 is a small update: your own requests wait for a busy Mac instead of failing, a pair you run
yourself no longer drops a short request queued behind a long prompt, and Nemotron 3.5 Super hands back network
requests it can't start in time so another Mac can serve them. Update with `darkbloom update`.

## Highlights

### Your own Mac and pair

- Requests on your own local API (one Mac, `darkbloom start --local`, a two-Mac pair's leading Mac, `cluster local`)
  that can't start because other requests hold the memory now wait their turn, for up to two minutes, instead of
  failing at once. When a Mac really is busy, the error says so and tells the client when to retry; only a request
  that can't fit even on an idle Mac is asked to be smaller. Agents such as Hermes no longer take a busy Mac for a
  conversation that's too long.
- On a two-Mac pair you run yourself, a short request sent while a long prompt is being read no longer fails after
  about ten seconds: your own requests are bounded only by their own deadline.

### Nemotron 3.5 Super

- A Mac serving Nemotron 3.5 Super now turns down at once a network request whose first output it can't deliver in
  time, judged by its own recent speed, instead of holding it until the time runs out. Darkbloom then gives the request
  to another Mac with almost all of its time left. Your own requests have no such time limit and are never turned down
  this way.

### Releases

- Release publishing tolerates slow downloads of the signed build, and the release page shows these notes.

## Upgrade notes

- **Pairs:** both Macs of a pair must run the same version. A pair on 0.10.14 updates itself, and a pair that serves
  only you comes back by itself after `darkbloom update` on both Macs. `darkbloom update --rollback` puts back 0.10.14.
- The security stack is unchanged: end-to-end encryption, attestation, signing and weight hashes are as in 0.10.14.

## For operators: turning a change off

Set the variable before `darkbloom start` (or `darkbloom cluster`); the installed service keeps it.

| Variable | What it restores |
|---|---|
| `DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS=0` | Your own requests are refused at once when the Mac is busy, as in 0.10.14 (in the new busy / too-large words) |
| `DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0` | A pair's own requests keep the first-token allowance, as in 0.10.14 |
| `DARKBLOOM_NEMOTRON_SUPER_FIRST_CONTENT_REFUSAL=0` | Nemotron 3.5 Super starts every network request, as in 0.10.14 |

The full technical changelog is in [CHANGELOG.md](https://github.com/Layr-Labs/d-inference/blob/v0.10.15/CHANGELOG.md).
