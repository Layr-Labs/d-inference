# Frozen long-reference provenance and postflight

Prospective CPU/source draft, frozen before reading the new candidate run.
The verifier runs no SSH, native code, tokenization or model payload hashing.
The separate postflight is root-only and performs read-only SSH observations.
No launcher module is imported or executed by either tool.

## Root-only postflight

The older solo postflight hardcodes another executable and launcher schema,
so it cannot be used unchanged. `postflight_remote_long_reference.py` instead
accepts an explicit expected native pin and the completed receipt pin. Its
fixed remote observation program is copied byte-for-byte from the prior
postflight: exact owned-path process inventory, memory, VM, hardware and OS
reads only. It does not kill processes, change files or perform model work.

```bash
python3 postflight_remote_long_reference.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --root-launcher-exit-code 0 --output <new-postflight.json>
```

Before any SSH call it checks successful launch/cleanup flags, canonical owned
paths, the pinned archive's worker/process source, exact rank configuration
identity and the expected native bundle. It does not compare the current
repository or current executable. It labels local SSH reaping and remote path
absence separately; remote `waitpid` proof is not asserted. The fixed command
has a 20-second SSH timeout and bounded stdout/stderr. Fake tests inject an
invoker; no actual SSH call occurred during preparation.

## CPU provenance replay

```bash
python3 verify_long_reference_provenance.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --artifact-aggregate-sha256 <registered-artifact-SHA256> \
  --configuration-sha256 <exact-original-config-SHA256> \
  --long-prompt-sha256 <raw-prompt-SHA256> --prompt-origin-sha256 <tokenization-receipt-SHA256> \
  --launcher-review <frozen-launcher-review.json> --launcher-review-sha256 <review-SHA256> \
  --origin-directory <retained-tokenization-origin-directory> \
  --postflight <root-postflight.json> --postflight-sha256 <postflight-SHA256> \
  --output <new-provenance-audit.json>
```

All expected model, input, native and review hashes are caller-supplied pins.
The accepted workload is deliberately the current 8,192/512/output-one native
reference contract, fixed 300-second native/worker deadline and parent at most
330 seconds. No old 65-token reference, solo timer or old executable identity
is embedded. The fake archive uses different coherent hashes to exercise this.

The replay verifies every listed archived source, bundle, launcher, input,
control, native output and retrieved metadata file. It binds the runtime/CLI
source pins in the frozen launcher review, source dependency declarations,
the exact rank command and three-variable arithmetic environment. The rank
must have empty input maps so the raw prompt cannot be JSON-rewritten.

The exact archived prompt must equal the retained origin prompt and actual
retrieved remote prompt byte-for-byte. The separately pinned tokenization
receipt binds source text, decoded prefix, preparation script and logical token
IDs. Those source files are hashed, not executed. Tokenizer identity is checked
against the retained model manifest declaration; tokenization semantics are
not independently rerun. Model manifest hashes, file counts and declared sizes
are recomputed, while full remote weight verification remains a pinned-control
attestation from before and after execution.

The reused, unchanged `remote_prefill_provenance_records.py` replays saved
control order and VM/swap/PID/RSS arithmetic. The additional contract requires
zero reported swap, both resource screens and the saved root postflight with
no owned paths present. No shared monotonic epoch between remote Python
processes is assumed. Sampled RSS is not a peak, and missing observations are
not zero.

Native stdout is only bounded, hashed and framed as exactly two opaque lines;
the producer's numerical rows, final state, release assertions and selection
belong to the separately frozen numerical oracle. This audit produces no
numerical, model-quality, memory-safety, physical-transport or throughput claim.
It also does not reproduce the native build or inspect a current remote host.
Later authorized live-tree changes are irrelevant: only the frozen run archive
and separately frozen audit/launcher/input provenance are compared.

## Prospective validation

Twelve CPU/fake tests exercise a complete invented archive and changes to
native/model/input/review pins, archived source/bundle/control bytes, raw prompt
encoding, origin source text, control identity, resource claims, zero swap,
output limits, ownership flags, postflight pins and path injection. All process
and socket entry points are blocked in those tests. Python 3.9 syntax checks
cover every file. The source manifest records the reusable helper and fixed
remote observation payload pins. No candidate file was read before freeze.
