# Three native state fixtures, ready for root review

The composed Gemma build passed for `WindowedRequestStateCheck`, `TargetVerificationSessionCheck`, and `TargetVerificationCheck`, including all three version/argument checks. Build receipt `07557bf2…6579` retained the same 3096 source and 8755 dependency members. No GPU case has run from this package.

`package/bundle/bundle.json` pins five files totaling 318,749,508 bytes: three new binaries and one shared copy of each unchanged native resource. All five were fully hashed before and after local copy. Bundle identity is `ad46a1f8…cdde`; `bundle-preparation.json` retains the exact copy result. The source-only finalization uses those recorded payload hashes, without rereading the large files while another compiler owns the slot.

This is a narrow derivative of `qwen-mtp-target-session-supervisor-v2-20260915`. The owned-child, resource, journal, parsing, and copy-stream helpers are unchanged. The supervisor selects one of three closed commands and uses a fresh process/run directory for each. Native alarms are 60 seconds for window/session and 30 for target; every invocation retains a 90-second parent and 135-second outer SSH deadline. The copy/package cap is explicitly 400 MB to accommodate the five-file shared bundle. Runtime numerical/resource limits are unchanged.

`window_result.py` requires the exact ordered 21 native groups, mixed BF16/FP32 types, window/chunk/frontier geometry and byte accounting. It also requires all unsupported-scope claims to remain false. The old session and target result validator bodies are preserved exactly. Each envelope records whether actual window state or target transaction/trunk execution was observed, separately from cleanup. Success still requires exit zero, complete output, reaped/absent owned group, unchanged source inputs, resource postflight and the same empty canonical journal inode. This is standalone device exclusion, not a protocol lease-release ACK.

Twelve Python methods passed in 0.114 seconds: output-contract negatives, wrong-fixture rejection, command/alarm bindings, all-three process names, six fake CPU children, and the prior cleanup ownership cases. The tool-combined output is retained. These are model-free checks; they do not establish native numeric success.

After review, the root can execute these commands individually from this directory:

```sh
python3 -B run_physical.py copy
python3 -B run_physical.py run --fixture window
python3 -B run_physical.py collect --fixture window
python3 -B run_physical.py run --fixture session
python3 -B run_physical.py collect --fixture session
python3 -B run_physical.py run --fixture target
python3 -B run_physical.py collect --fixture target
```

The fresh remote directory is `/Users/developer/DarkbloomDev/gemma-window-state-check-20260916` on `darkbloom-24`. `ROOT-COMMANDS.json` retains the existing dedicated dev SSH identity and pinned known-hosts path, with no credential contents. Each used action/run directory is exclusive and cannot be overwritten. The root should inspect each terminal/cleanup result before proceeding; nothing automatically launches the next fixture after failure.

Pending: root source review, copy/remote preflight, and three actual GPU fixture executions. Even if these pass, no Gemma checkpoint inference, outer Gemma memory admission, distributed Gemma execution, MTP proposal/acceptance, or bilateral wire verification is claimed.
