# Frozen long-solo provenance and postflight

Source and fake-CPU adapter for the registered 8,192/512/output-one solo
diagnostic. No candidate output was read before freeze. The verifier performs
no SSH, native execution, tokenization or model payload hashing. Its separate
postflight is a root-only read-only SSH observation tool.

## Root-only postflight

```bash
python3 postflight_remote_long_solo.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --root-launcher-exit-code 0 --output <new-postflight.json>
```

The postflight accepts only the completed long-solo launcher namespace and
explicit native pin. Before SSH, it verifies success and cleanup flags,
canonical owned paths, the pinned archive's worker/process sources, owned rank
configuration and native bundle. Its remote observation payload is byte-for-byte
the frozen long-reference payload: exact owned-path process inventory, memory,
VM, hardware and OS reads. It does not kill processes or modify files.

The SSH call has a 20-second timeout and bounded stdout/stderr. Local SSH
reaping and remote path absence are separate facts; remote `waitpid` proof is
not asserted. Injected fake calls exercise this path without actual SSH.

## CPU provenance replay

```bash
python3 verify_long_solo_provenance.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --artifact-aggregate-sha256 <registered-artifact-SHA256> \
  --configuration-sha256 <exact-original-config-SHA256> \
  --long-prompt-sha256 <raw-prompt-SHA256> \
  --prompt-origin-sha256 <tokenization-receipt-SHA256> \
  --launcher-review <frozen-solo-launcher-review.json> \
  --launcher-review-sha256 <solo-review-SHA256> \
  --origin-directory <retained-tokenization-origin-directory> \
  --postflight <root-postflight.json> --postflight-sha256 <postflight-SHA256> \
  --output <new-provenance-audit.json>
```

All model, input, native and review hashes are explicit caller pins. The native
command must be `qwen-long-prefill-solo-check`, 8,192 prompt tokens, chunk 512,
output one, no teacher tokens, repeats one, warmups zero, and a 300-second
native/worker deadline. The parent deadline is at most 330 seconds. Full solo
forward and diagnostic timing intent must be true; reference/stage forward and
throughput qualification flags must be false. No binary identity is hardcoded.

The solo launcher's frozen review is a delta over the reference launcher.
`long_solo_launcher_review.py` verifies its explicit review pin, 18-test
declaration, pinned upstream review and the exact eight unchanged helper hashes.
Keep that upstream review at the retained sibling location
`../remote-long-reference-launcher-draft/source-review-20260914.json` relative
to the solo review directory. The upstream stable runtime/reference-CLI source
pins are checked against the run's archived source inventory. New solo sources
are covered by the complete archived source manifest and caller's native pin;
this is not an independent reproduction of the native build. The historical
review's pending-peer annotation is not converted into a peer-review pass.

Every listed source, bundle, launcher, input, control, native-output and copied
remote-metadata file is hashed. Exact native arguments and three-variable
arithmetic environment are bound. Empty rank input maps preserve the raw
prompt: retained origin, archived local prompt and retrieved remote prompt
must agree byte-for-byte. The origin receipt binds preparation source, natural
text, decoded prefix and logical token IDs; tokenization is not rerun. Remote
full-artifact hashing remains a before/after pinned-control attestation.

The unchanged resource helper replays saved control order and VM/swap/PID/RSS
arithmetic: initial actual free at least 6 GiB, post-hash reclaimable estimate
at least 8 GiB, pressure at most two, zero reported swap and final owned-process
absence. The root postflight must also pass. These are observed gates, not a
memory-safety guarantee. RSS is sampled, not a peak; missing observations are
not zero. No shared monotonic epoch across remote Python processes is assumed.

Native stdout is bounded to 8 MiB and exactly two opaque lines. Stderr is bounded
to 64 KiB and must be empty. Numerical values, native timing intervals, four
native memory phases, model/state release assertions and token selection remain
the separate numerical oracle's responsibility. This verifier makes no timing,
numerical, physical-transport or throughput claim and never compares today's
working tree to an earlier authorized build.

## Prospective validation

Fifteen fake CPU tests cover a complete invented archive, wrong explicit pins,
changed source/bundle/control/raw-input/origin bytes, exact mode/environment,
timing intent, upstream helper and dependency drift, resource/replay/zero-swap
gates, output caps, path injection and postflight source/ownership claims.
Real process/socket entry points are blocked. Python 3.9 syntax checks cover
every Python file. The freeze records unchanged helper and remote payload
hashes. No native, SSH, model payload or new candidate run is used.
