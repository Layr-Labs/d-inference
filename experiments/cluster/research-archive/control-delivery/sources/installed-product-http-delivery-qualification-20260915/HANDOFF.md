# Normal HTTP recovery on the HTTP-delivery build

This is a new source-only derivative of the frozen diagnostics V2 harness. All 32 predecessor manifest members were verified. `runtime.patch` changes only two runtime-path constants, the expected status cluster/configuration binding, and the corresponding model-free tests. `run.py`, status capture, resource policy, alias lease, native cleanup observations and external client are unchanged. No compiler, SSH, native, physical request, credential read or MAIN edit was performed by this agent.

`bindings.json` records Provider `c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350`, unchanged native `ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5` and capability `7e8a1480f1c8831cf447fa2f51935bf5e3b79024b1b83c09aa2df0bb6df883e7`. Binary installation/pins are root's deployment evidence, not a new remote preflight performed by this inherited harness.

The locally derived canonical configurations are in `configuration/`. Python compact sorted JSON plus one LF first reproduced both old actual Swift configure hashes exactly. Only cluster ID and both peers' executable paths changed; prefill was already explicitly lookahead. Current `ClusterConfigurationCodec.encode` uses sorted keys/unescaped slashes/one LF, and Store makes the existing selection explicit before hashing. Leader expected hash is `d787ce64ed4249048c195ab02cedefcda50558fe69b7d7063e08c33f373da588`; follower is `2228dec1f648ca8aa973eb3adde9d08d97dd11ed8a2e182c2f740285a5fc0144`. Root reports actual configure on both hosts matched these pins. Provider TOML hashes depend on host state and were supplied by root, not derived. The new status validator additionally requires the exact leader configuration hash.

## Root-run short recovery

After independently confirmed prior cleanup, run from this directory:

```sh
/usr/bin/python3 -B run.py --attempt 1 \
  --prompt-file ../installed-http-client-draft-20260915/prompts/short.txt \
  --client ../installed-http-client-draft-20260915/client.py
```

The existing 139-byte short prompt is SHA256 `b6bf7a399d76fcf320afb980274ed56b904919dc5d239f9f8d28da2de0ec0473`. The client requests up to 128 outputs with thinking disabled and greedy settings. No prompt-token count is guessed; actual server usage is retained. The client and all 20 members of its existing frozen manifest were verified, not copied or changed. It already ignores SSE comment lines; comments do not become content/token evidence.

Local output is `physical-1`; remote leader output is `/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915/qualification/attempt1`. These do not collide with cancellation's `cancel-<mode>-attemptN` remote paths. Existing output directories refuse overwrite. A later run needs a fresh attempt number and independently established cleanup. This command is documented, not executed by this agent.

## Remote helpers

Both hosts use `/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915/qualification-tools/` with these exact five files; `remote-helpers.json` contains their hashes:

- `supervisor.py` (used only on leader)
- `monitor.py`
- `reference_resources.py`
- `stage_checks/__init__.py`
- `stage_checks/common.py`

All five are byte-identical to root's prepared HTTP-delivery cancellation helper set. No additional remote status helper is needed: status capture runs the installed `darkbloom cluster status --json`. No helper replacement is needed if root's five installed files have those same pins.

## Validation and scope

`checks-1` passed 14 tests in 0.389 seconds total: the inherited status cases, five actual local Python child outcomes, old cluster/configuration rejection, and exact new status command binding. All 14 Python files parse as Python 3.9. Eleven inherited test bodies are byte-equivalent by AST; the stopped-fixture assertion now explicitly names its historical cluster. The captured stopped-status fixture remains byte-identical and is never relabeled as new observed readiness. New cluster/config selection and live values are explicitly fabricated only in tests. Current seven status DTO/codec/source pins remain unchanged from the predecessor.

Before/after live authenticated status is outside client TTFT. It requires the actual two native-ready ranks, fresh nonce, same epoch/binding and one consumed admission. Normal success still requires the existing client success, clean supervisor, absent native processes, empty journals, alias restoration, resource observations and unchanged input pins. Local command exit is not remote native cleanup proof; configuration or PID alone is not readiness. This increment does not qualify cancellation, typed deadline delivery, tensor numerics, representative performance or OpenRouter. Independent root review and physical execution remain separate.
