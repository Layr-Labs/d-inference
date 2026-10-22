# Frozen long-pair provenance and postflight

Prospective CPU/source adaptation of the frozen long-reference verifier. No
pair candidate archive or output was read during preparation. The verifier
runs no SSH, native code, tokenization or model payload hashing. The separate
postflight is root-only and performs read-only SSH observations. Neither tool
imports or executes a launcher module.

The accepted contract is one process running `qwen-long-prefill-pair-check`,
with full-reference and stage forwards requested, 8,192/512/output-one, no
teacher tokens, a 300-second native/worker deadline and parent at most 330
seconds. This is a sequential full-model/reference-to-stages comparison, not
physical distributed execution. Expected native/model/input hashes are explicit
caller arguments; no earlier executable or 65-token reference is embedded.

## Root-only postflight

```bash
python3 postflight_remote_long_pair.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --root-launcher-exit-code 0 --output <new-postflight.json>
```

Before SSH it checks successful launch/cleanup flags, canonical owned paths,
the archive's worker/process source, rank configuration identity and expected
native bundle. It does not compare the current repository or executable. Its
fixed remote program is unchanged from the reference postflight: exact owned
path process inventory and memory/VM/hardware/OS reads only. It does not kill,
change remote files or perform model work. The command has a 20-second timeout
and bounded stdout/stderr. Local SSH reaping and remote path absence are
reported separately; independent remote `waitpid` proof is not asserted.

## CPU provenance replay

```bash
python3 verify_long_pair_provenance.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --artifact-aggregate-sha256 <registered-artifact-SHA256> \
  --configuration-sha256 <exact-original-config-SHA256> \
  --long-prompt-sha256 <raw-prompt-SHA256> \
  --prompt-origin-sha256 <tokenization-receipt-SHA256> \
  --launcher-review <frozen-pair-launcher-review.json> \
  --launcher-review-sha256 <review-SHA256> \
  --origin-directory <retained-tokenization-origin-directory> \
  --postflight <root-postflight.json> --postflight-sha256 <postflight-SHA256> \
  --output <new-provenance-audit.json>
```

The replay verifies every listed archived source, bundle, launcher, input,
control, native output and retrieved metadata file. The new pair launcher review
contains absolute flat file paths; only exact files inside that independently
pinned review directory are normalized into archive names. Outside/nested paths,
symlinks, duplicate names and hash changes are rejected. Its eight-test CPU proof
and Python 3.9 syntax declaration are required. The review's historical pending
peer-review annotation is not promoted into a passed review claim.

The five runtime/CLI dependency pins in that review must match archived source;
later authorized live-tree builds do not enter this audit. All launcher Python
files must match the frozen review inventory. Native bundle, source dependency,
control and input identities remain bound before and after the saved run.

The rank must use exactly the pair mode, three-variable arithmetic environment
and empty input maps. The archived raw prompt must equal the retained origin
prompt and retrieved remote prompt byte-for-byte. The separately pinned origin
receipt binds source text, decoded prefix, preparation script and logical token
IDs. Those files are hashed, not executed. Tokenizer identity is checked against
the retained model manifest; tokenization is not repeated. Full remote model
verification remains a saved, pinned-control attestation.

The unchanged resource helper replays control order and VM/swap/PID/RSS
arithmetic: initial actual-free 6 GiB, post-hash reclaimable 8 GiB, pressure at
most 2 and zero reported swap, plus the saved root postflight with no owned paths
present. No shared remote monotonic epoch is assumed. Sampled RSS is not a peak,
and missing observations are not zero. These screens do not prove memory safety.

Native stdout is bounded and hashed as exactly two opaque complete lines: the
reference checkpoint and pair terminal record. Their JSON, numerical rows,
merged state, selection and model/request-release assertions belong to the
separately frozen numerical oracle. This verifier makes no numerical, native
byte-comparison, physical-transport or throughput claim and does not reproduce
the build or independently inspect a current remote model payload.

## Prospective validation

Fourteen CPU/fake tests exercise a complete invented archive and mutations of
explicit pins, source/bundle/control bytes, raw prompt/origin, mode, deadlines,
cleanup flags, control identity, resource claims, zero swap, output bounds,
postflight identity and path injection. Two focused additions reject the old
reference kind/mode and unsafe absolute review paths. All real process/socket
entry points are blocked. Python 3.9 syntax checks cover every source file.
The source freeze binds the prior verifier, unchanged helper/payload, pair
launcher review and individual files; no actual SSH or native run is performed.
