# Prospective v4 long-rank provenance and postflight

These tools qualify saved execution provenance for one 8,192/512/output-one
cohort on one remote host with two loopback ranks. Expected native, artifact,
configuration, raw prompt, origin, launcher-review and postflight hashes are
explicit caller arguments. They contain no old executable pin or 65-token
input assumption. No candidate run was read during development or CPU tests.

`verify_long_rank_provenance.py` performs only local CPU/file work. It never
imports a launcher or native module, starts a process, opens a socket, reruns
tokenization or reads model payloads. Native stdout remains two opaque complete
lines per rank; the separate numerical/wire/action/timing oracle owns their
contents. The source freeze and caller's explicit pins must be retained with
each audit.

## Root-only read-only postflight

```bash
python3 postflight_remote_long_ranks.py <frozen-run-directory> \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --policy serial_v1 --root-launcher-exit-code 0 \
  --output <new-postflight.json>
```

The same tool admits `prompt_lookahead_one_v1` when explicitly selected. Before
SSH it verifies the successful cohort, two distinct reaped local client PIDs,
canonical unique remote rank paths, archived worker/process sources, both exact
rank configurations and native bundle pin. Its fixed read-only remote program
is byte-identical to the earlier v3 rank postflight: owned-path process inventory
and memory/VM/hardware/OS observations only. It performs no kill or remote file
mutation, and has a 20-second timeout and bounded returned output. Fake tests
inject an invoker; no actual SSH was run during preparation.

Only receipt/native/policy are independent postflight inputs. Other model/input
pins are checked independently by the CPU verifier. Local SSH reaping and remote
path absence are separate facts; independent remote `waitpid` proof is not claimed.

## CPU archive and saved-resource replay

```bash
python3 verify_long_rank_provenance.py <frozen-run-directory> \
  --policy serial_v1 \
  --receipt-sha256 <completed-launcher-receipt-SHA256> \
  --expected-native-sha256 <that-run-native-SHA256> \
  --artifact-aggregate-sha256 <registered-artifact-SHA256> \
  --configuration-sha256 <exact-original-config-SHA256> \
  --long-prompt-sha256 <raw-prompt-SHA256> \
  --prompt-origin-sha256 <tokenization-origin-receipt-SHA256> \
  --launcher-review <frozen-launcher-review.json> \
  --launcher-review-sha256 <review-SHA256> \
  --origin-directory <retained-tokenization-origin-directory> \
  --postflight <root-postflight.json> --postflight-sha256 <postflight-SHA256> \
  --output <new-provenance-audit.json>
```

The accepted command is exactly `qwen-long-prefill-rank-check`, v4 flow,
the selected policy, native BF16 logits, seed 7, one request, no warmup/teacher,
300-second native/worker timeout and at most 330-second parent timeout. Both
rank configurations require empty `input_files`, rank-specific `MLX_RANK`, the
three arithmetic variables and `MLX_HOSTFILE` pointing to the already staged
file. Loopback endpoints must be distinct canonical `127.0.0.1:port` values.

The complete archive inventories bind source, dependency declarations, bundle,
launcher, controls, both ranks' five files, origin inputs and ten retrieved
metadata files. Each warning stream must be exactly the one source-derived
loopback warning line. The actual archived `Collective.swift` and `Options.swift`
logger hashes are recorded per run, so an authorized later CLI addition is not
mistaken for a stale pre-build Options pin. Reviewed dependency pins apply to
the archive; no current working-tree or current executable comparison is made.

Both local rank prompts, both retrieved remote prompts and the retained origin
prompt must match the independently pinned raw bytes. Both local/remote host
files must match the exact staged encoding. Before and after controls must bind
both raw copies, their sizes, bundle/native/model identity and rank configs.
Origin source files are hashed without executing the preparation script or
tokenizer. Remote full-model verification remains a saved pinned-control
attestation, not a fresh payload hash performed by this verifier.

The unchanged common resource helper replays the initial 6 GiB actual-free
screen, post-hash 8 GiB reclaimable screen, pressure at most 2, zero reported
swap and saved control order. Each rank must have exactly one observed native
PID and supervisor PID, with four distinct remote owners and exact per-rank
command paths. Observed native group leaders and parent relationships are
checked where both rows exist. Duplicate/wrong-rank attribution and restart
summaries are rejected. This extra evidence requirement is explicit: absent
samples are never replaced with invented process observations.

Per-rank RSS and simultaneous sums exclude supervisors from the native sum and
remain sparse samples, not memory peaks; missing values are not zero. Separate
remote Python monotonic epochs are not assumed comparable. Final saved samples
and the pinned root postflight must show no owned processes. The tools make no
whole-process memory-safety, independent remote reaping, physical transfer or
throughput qualification claim.

Thirteen prospective fake CPU tests cover complete serial/lookahead archives,
explicit pins and old namespaces, exact rank/raw/environment/endpoint identity,
warning variants, archive escape/symlink/output bounds, process attribution,
resource/control replay and postflight failures. All real process/socket entry
points are blocked. Python 3.9 syntax and frozen source/helper/payload identity
checks accompany the source manifest. No native build or execution occurs here.
