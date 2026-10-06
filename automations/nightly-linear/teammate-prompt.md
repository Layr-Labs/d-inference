# Paste into Codex once

This prompt works after the shared workflow files are merged into
`Layr-Labs/d-inference` on `master`, its current default branch.

```text
Set up my nightly Darkbloom Linear update from
https://github.com/Layr-Labs/d-inference.git, branch master.

Create a dedicated workflow clone, read automations/nightly-linear/setup.md
from that branch, and follow it. Use my own Linear account and my relevant
Darkbloom work history from Codex, Claude Code, and Pi.

I authorize the setup, fetching future updates from this repo branch,
and the routine Linear issue updates described in that playbook. Route
unclassified new work to the existing Others project.

Run a read-only preview, then create the automation for 10 p.m. every day
in my local time zone. Each run must fetch and use the current repo skills
and playbook. Keep personal configuration and recovery state outside
the clone, and give me the manual "run now" prompt when setup is complete.
```

After setup, use the manual invocation Codex provides to run the same saved
launcher immediately. Ordinary playbook updates require no new teammate prompt.
