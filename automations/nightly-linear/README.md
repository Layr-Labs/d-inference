# Nightly Linear updates

This package reviews one person's Darkbloom work in Codex, Claude Code, and Pi,
then reconciles it with their Linear issues. Unclassified new work goes to the
existing Others project. Each teammate installs once in a local Codex desktop
chat; each run fetches this repo's configured branch before loading the playbook.

## Teammate setup

After this package is merged into `Layr-Labs/d-inference` on `master`, copy the
prompt in [teammate-prompt.md](teammate-prompt.md) into Codex. It reads
[setup.md](setup.md), connects the person's own Linear account, verifies their
work roots, previews proposed changes, and creates the daily automation.
The default time is 10 p.m. in that person's local time zone.

Setup creates a dedicated clone, links the two repo skill folders into the
supported Codex user skill directory, and saves a small local `run.md` launcher.
The manual “run now” invocation and schedule share that launcher and recovery
state. The local launcher is separate from this package's shared `run.md`.
Git and Python 3 are the only script dependencies. Nothing is installed in
Claude Code or Pi.

## Package contents

| File | Purpose |
| --- | --- |
| [teammate-prompt.md](teammate-prompt.md) | Short, one-time copy/paste prompt. |
| [setup.md](setup.md) | Installation and scheduling instructions. |
| [run.md](run.md) | Shared run instructions loaded on each trigger. |
| [refresh.py](refresh.py) | Fetch a managed clone and return one commit's instructions. |
| [skills/darkbloom-work-history/SKILL.md](skills/darkbloom-work-history/SKILL.md) | Gather relevant work with source evidence. |
| [skills/darkbloom-linear-nightly/SKILL.md](skills/darkbloom-linear-nightly/SKILL.md) | Match issues, apply authorized updates, and recover interrupted writes. |
| [config.example.json](config.example.json) | Shape of private, per-person configuration. |
| [state.example.json](state.example.json) | Initial recovery state for a new installation. |
| [tests/test_refresh.py](tests/test_refresh.py) | Isolated local Git integration tests. |

The skills intentionally live with this workflow. Setup exposes them through
[symlinked user skill folders](https://learn.chatgpt.com/docs/build-skills).

## Updating the shared workflow

Edit the canonical skills or shared `run.md` here and push to the configured
branch, currently `master`. Every trigger calls `refresh.py` with the person's
absolute `config.json` path. Successful output contains the fetched commit ID,
both skill bodies, and the playbook. All instruction bodies come from that one
commit, even if older skills were already loaded in the chat.

The updater fast-forwards only the dedicated managed clone. Failed fetches stop
before Linear writes; local edits, unexpected files, and divergent commits are
preserved for repair. Personal configuration, checkpoints, pending actions, and
run reports stay outside the clone, normally in `~/.codex/nightly-linear/`.
Do not commit them to this repository.

Ordinary playbook changes need no replacement setup prompt. A change to the repo
URL, branch, permissions, personal scope, or launcher contract can require a
one-time setup adjustment. Preserve checkpoint and pending-action data when
changing its format.

## Verification and rollout

From the repository root:

```bash
python3 -B -m unittest discover -s automations/nightly-linear/tests -p 'test_*.py'
```

Tests use temporary local Git repositories and do not contact Linear or GitHub.
The scoped GitHub Actions workflow runs the same checks for package changes.

Before team rollout, pilot one teammate: inspect the preview, run the saved
launcher manually, and verify the Linear changes and recorded revision. Push a
small playbook change and run again to confirm the revision updates without
duplicating captured facts. Then share the same teammate prompt with everyone.

Installation, connector access, scheduled permissions, and unattended updates
must be verified on each person's machine. Local
[scheduled tasks](https://learn.chatgpt.com/docs/automations) require the computer
to be on and the desktop app running. This repository packages the workflow;
it does not contain anyone's live schedule or Linear credentials.
