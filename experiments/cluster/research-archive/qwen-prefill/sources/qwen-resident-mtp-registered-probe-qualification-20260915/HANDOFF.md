# Registered 9B single unaccepted MTP proposal: prospective physical package

This private package prepares one real P32/C16/O2 request using cut4, serial prefill,
greedy target selection and no stop IDs. It reuses the existing one-request SSH
controller and owner protocol. No speculative target acceptance is implemented.
The ordinary target emits two tokens; rank1 proposes once between those selections.
The proposal may match or differ from target token2. Neither result makes it accepted.

Native binary: `34fcd255f3bab741586476867da26035cfd0ee0f2ba6ee708551c07d0bdbcba1`.
Native source snapshot: `36c41b6508c95390eb975df63117d679d94e8030855fb869a90fe46421106598`.
Its actual26.2/JACCL build passed217.744s; no registered forward has run yet.
The exact matched metallib and paged-attention source are in `runtime/bundle.json`.
The earlier tiny actual48GB GPU numerical fixture passed separately; that is not
an independent numerical reference for this registered request.

Request UUID: `18901e32-47f8-4fc8-a8bd-ec3fbdcf118e`.
Membership epoch: `6a5c1ca9-076f-4392-85fa-a7fbf33c3f68`.
`request.json` is unchanged from the frozen probe overlay. `configuration/lineage.json`
binds its retained prompt source, native identities, common arithmetic and opaque
storage commitment. The storage commitment comes from previously qualified source
receipts; the Python comparison does not independently reconstruct model storage.

## Existing control and exclusion

`controller/owner-controller` and its four dylibs are exact copies of the original
one-request build-v3 closure. Each remote owner and its four dylibs are the exact
wakeup closure in `owner/bundle.json`. They are separate sets, with no dylib mixing.
The common Remote dylib is byte-identical. The historical one-request controller
can quarantine on failed admission; this package does not claim healthy same-epoch
recovery, retry or automatic journal clearing.

Both new owner configs use `/Users/developer/.darkbloom/cluster-device`. The old compiled
Remote module uses its internal `ClusterDeviceLease`, not today's class. Its
`openat` on `native-device.lease`, nonblocking exclusive flock, empty-journal gate,
record-before-launch and terminal+release-before-clear match the current provider's
same file/lock protocol. `exclusion-review.json` pins the exact lines and both source
versions. The older implementation lacks newer post-acquire path and recorded-byte
checks; no claim is made that it contains those changes. No private substitute lease
is created. A nonempty canonical journal must remain a refusal.

The new remote trees are `/Users/developer/DarkbloomDev/owner-native-mtp-probe-20260915` and
`/Users/developer/DarkbloomDev/qwen-mtp-registered-probe-runtime-20260915`. Existing installed
settings, owners and bundles stay unchanged. `deploy_copy_only.py` copies only these
NEW trees using explicit identity and pinned known-host options, refuses existing
paths and fully rehashes the installed closure. It never runs an owner/native model.
The canonical journal is observed without mutation. Copy observations do not prove
that the device remains free at the later launch.

## Root launch and evidence

After reviewing deployment receipts, root performs fresh resource/process/journal
preflight and owns the real launch:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-registered-probe-qualification-20260915
/usr/bin/python3 -B run_physical.py
```

The whole existing physical wrapper function/class bodies are unchanged; only its
private paths, controller closure and explicit SSH identity/known-host arguments
change. `assembly-lineage.json` records this. It retains original resource sampling
(6GiB actual free, pressure0...2, AC and zero reported swap), the existing temporary
RDMA alias lease and restoration, raw controller streams and315s outer timeout.
The Swift controller creates same-Mac deadlines:300s owner lifetime,90s startup,
120s request,305s final alarm. Python monotonic values are observations only and are
never sent as Swift uptime deadlines. The original resource monitor is observational;
the native workers retain their actual resource gates. No new supervisor is added.

Root must retain both sidecars (named by the request UUID), controller started/result
records, process/journal postflight on both hosts, alias restoration and raw resource
samples. Success requires ordinary target2 completion, assistant retirement, both
native cleanup observations and authenticated lease ACKs, exit0, unchanged pins,
empty canonical journals and no remaining owner/native processes. Time/EOF alone
cannot replace those proofs. A failed run remains failed; do not reuse its epoch.

```sh
/usr/bin/python3 -B validate_probe.py --rank0 /absolute/rank0.json --rank1 /absolute/rank1.json --controller /absolute/controller.stdout.jsonl --output /absolute/new-comparison.json
```

The validator checks its prospective policy pins before candidate access. It checks
strict schemas, both target IDs, agreement/identity, final3frames/frontier33,
assistant history31→32, unaccepted proposal binding and both controller cleanup/ACK
claims. It deliberately does not independently attest cleanup, resources, installed
binaries, opaque hashes, token-chain reconstruction or target numerical correctness.
Those require the root's separate physical evidence. No throughput, TTFT, MTP-enabled
serving or accepted-prefix generation claim is supported by this probe.

Twelve model-free CPU methods passed, including two actual Python CLI children and
negative phase/history/ownership/schema cases (`tests.json`). No candidate sidecar
was accessed before freezing this policy. The first local package assembly assumed
a `files` key for the native bundle; its preserved failure was corrected to the
actual `entries` format without touching native artifacts.
