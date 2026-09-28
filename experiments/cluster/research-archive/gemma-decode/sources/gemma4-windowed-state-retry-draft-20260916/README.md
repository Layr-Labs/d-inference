# Gemma native state checks: explicit retry

This successor installs one new, source-pinned operational entrypoint under the existing verified installation. It reuses the exact three native binaries, resources, source contracts, resource gate, supervisor, result validators and canonical device gate from `gemma4-windowed-state-supervisor-20260916`. No native or model execution occurred while preparing it.

The first window attempt remains a prelaunch resource refusal: root reported 5,420,122,112 actual-free bytes against the unchanged 6 GiB requirement, with no native process and an empty journal. Its evidence is preserved. A successful retry would be separate evidence, not a revision of that failure.

Only `/Users/developer/DarkbloomDev/gemma-window-state-check-20260916/operations-retry-20260916/run_target.py` is installed. The installer refuses an existing operations directory, validates the exact original package manifest, and never replaces an original file. The entrypoint requires its own SHA256 in addition to the original package SHA256; the existing `Pins` implementation checks both before launch and rechecks the new entrypoint during teardown.

`--attempt` accepts integers 1 through 9, default 1. Each remote run uses `runs/<fixture>-<attempt>`; each local action has a matching fresh directory. Exclusive directory creation refuses used attempts. Assignment of the active run occurs only after that creation succeeds, so a refused duplicate cannot write a failure record into an existing incomplete attempt. Copy remains a single operation, with no fixture and attempt 1 only.

The parent remains bounded to 90 seconds, SSH to 135 seconds, native window/session alarms to 60 seconds and target to 30 seconds. AC, pressure, zero-swap and 6 GiB actual-free checks are unchanged. This does not provide automatic retry, cache purging, journal recovery or signal changes.

Root commands, after source review and when the physical slot is granted:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/gemma4-windowed-state-retry-draft-20260916
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py copy
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py run --fixture window --attempt 2
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py collect --fixture window --attempt 2
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py run --fixture session --attempt 2
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py collect --fixture session --attempt 2
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py run --fixture target --attempt 2
/opt/homebrew/opt/python@3.14/bin/python3.14 -B run_physical.py collect --fixture target --attempt 2
```

Run and collect each fixture separately; root reviews cleanup before the next launch. The local wrapper verifies this frozen manifest, the original frozen manifest and its members, plus the unchanged pinned SSH trust file. That later root-run verification includes the original native payloads; preparation here did not reread or copy them. The copy stream is capped at 1 MiB and the new source is 5,402 bytes. No credential contents are retained.

Nine small Python checks passed in 0.073 seconds. They exercise the actual argument prefixes, existing-attempt refusal, preservation of attempt 1, actual `Pins` change/symlink refusal, command bindings and exact source inverses. The remote entrypoint temporary-file cases stop before package/resource/native access. The native and SSH paths have not executed. Runtime changes are in `runtime.patch`; `source-checks.json` binds the tests and the unchanged outer subprocess, copy producer and installer cleanup bodies.
