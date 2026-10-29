# Registered control-only cluster members

Private source candidate. No member code has been compiled, deployed, or run.
The separate verified-pair V2 base is now MAIN and passed its 15 focused and
1,051 registry methods with Go's race detector on 2026-09-16. Those results do
not qualify this new role/negotiation/CLI overlay.

## Behavior and boundaries

`start --cluster-member` runs a foreground coordinator control process using
its saved installed cluster. `start --local --distributed` retains the same
control process inside the leader alongside the existing local HTTP host.
Both use the existing ProviderLoop, CoordinatorClient, authentication,
Secure Enclave registration, APNs code challenges, signed attestation challenge
responses and heartbeats. No second transport or inference engine is added.

The wire role is `execution_role: cluster_member`. Omission remains the exact
legacy solo representation. A member sends `models: []`; its selected model
inventory is in `cluster_models`. An older coordinator ignoring new fields
therefore receives no solo model inventory. A new coordinator binds the role
immutably to the connection and sends `cluster_member_accepted`, echoing a
fresh 64-hex registration nonce and its provider connection ID. The client
publishes `connected` only after a matching, timely, nonduplicate ACK. A missing
ACK fails after ten monotonic seconds; there is no downgrade. The ACK proves
protocol support only, before attestation completes. It is not readiness,
verified hardware, native authorization, a key, or permission to infer.

The common routing/liveness gate, private self-route, QuickCapacityCheck,
warm/load planning and model-command commit reject member-role connections,
even if they advertise models or loaded/empty capacity. Empty desired-model
revocation remains permitted. The pair-only eligibility context bypasses only
the role restriction and its own exact hold; all existing V2 catalog, hardware,
process-key, code/release, freshness and ownership checks remain in force.
V2's active reconnect quarantine and exact-release observations are unchanged.

Provider member mode skips solo startup preload, local solo endpoint, model
persistence, cache maintenance, idle/capacity/update monitors, MTP work and
prefetch construction. The existing central loader and direct inference,
load_model and prefetch handlers refuse the role before decoding or loading.
Desired models are not retained for future retries. Heartbeats carry an empty
solo slot set and zero free-for-load capacity; they do not probe MLX memory or
claim native readiness. Capacity probes do not evaluate solo geometry.

## Startup, loss and ownership

The CLI first holds the existing media/PID process lock. Member preparation
briefly takes the SAME canonical ClusterDeviceExclusion used by solo/native
owners, requiring an empty journal and exclusive lock; it never truncates,
resolves, or clears a journal. It validates the installed configuration,
manifest, tokenizer/trust inputs and runtime metadata for either local rank.
It releases the empty exclusion before registration/native launch. The actual
native owner must still take and retain its own canonical lease.

Preparation performs one selected-model integrity read with the existing
WeightHasher, checked against the pinned product aggregate. This synchronous
hash has NO cancellation/deadline API. Its duration is outside the metadata
probe's fifteen-second budget. The CLI owns and awaits it; no native owner or
ACK wait starts before it finishes. There is no bounded-whole-startup claim.

The existing immutable anonymous metallib binder is required before collecting
registration claims: without it `metallibHash()` is nil and release attestation
cannot succeed. Its native setter only assigns a path string; this path calls
neither requireMetal nor a GPU capability diagnostic. Hardware-only capability
claims are retained; no NAX/native-kernel capability is fabricated. A selected
model needing an unproven capability fails the existing requirement gate.

The local leader waits up to thirty seconds AFTER preparation for accepted role
negotiation before starting its existing installed session. Once accepted,
control disconnect/runtime invalidity/untrust latches a stop requirement. The
event loop closes and joins its transport, and the retained leader observer
stops the existing host. Host/native retirement and lease ACKs remain owned by
the existing lifecycle. Listener/control completion is never a fabricated
native release. Follower-only mode may reconnect, with a fresh nonce and local
connection identity; no prior grant/key is carried. The new handshake timer
and CLI waiters compare their exact nonce/wait UUID so late cancelled tasks
cannot poison replacements.

## Tests and build plan

Four new Go methods cover legacy/closed role decoding, old-decoder empty model
inventory, real route/QuickCapacity/warm/load/command exclusions, strict pair
eligibility, immutable role and connection replacement, and active grant
quarantine on reconnect. Run the new bounded Tests/run.py only after the root
compiler grant. It reuses the exact V2 owned-process helper, offline Go 1.25,
-race, -p 2, 120s Go/300s parent bounds and verified private source copying.
Focused selection includes the retained 15 verified-pair methods. A fresh
output is required for every invocation. Full mode covers registry+protocol.

After the compiler grant, from this directory:
```sh
python3 -B Tests/run.py --repo /Users/developer/DarkbloomDev/d-inference --output /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-focused-1-20260916
python3 -B Tests/run.py --repo /Users/developer/DarkbloomDev/d-inference --output /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-all-1-20260916 --all-registry
```
Run the second command only after the first succeeds. Preserve any failed
output and use a new output name for a corrected attempt.

The API registration-handler typecheck belongs to the combined Go build; this
narrow runner does not pretend to compile the API package.

Swift fixtures are in the existing ProviderCoreTests target:
- ClusterMemberRegistrationTests: normal/raw-attestation wire omission,
  inventory separation, ACK roundtrip/wrong nonce/role/duplicate/deadline,
  old ACK and stale timer against replacement, plus two real local WebSocket
  cases using the existing MockCoordinator (explicit ACK / old-server timeout).
- ClusterMemberLoopTests: direct inference/load/prefetch/desired rejection,
  empty state/no maintenance, incompatible solo endpoint, connection reset,
  accepted leader loss latching stop, expired/cancelled startup wait.
- DistributedStartCommandTests retains existing cases and adds explicit member
  flags and coordinator override now valid for the registered local leader.

Root should materialize an exact current Provider source/dependency snapshot,
apply integration.json with base checks/backups, then use its existing bounded
jobs-2 Provider build runner and filter:
`ClusterMemberRegistrationTests|ClusterMemberLoopTests|DistributedStartCommandTests|DistributedStartSessionFactoryTests|CoordinatorClient|StartupPreload|EngineV2SupportedSetGateTests`
Broaden after concrete failures or the final integration review. No model,
Secure Enclave credential, real coordinator, native worker or remote Mac is
required by these fixtures. Local WebSocket cases are fixture transport only.

## Not enabled by this increment

The verified-pair registry still needs authenticated grant delivery, explicit
owner-start acceptance and cleanup/release wire handlers. No native key is
established or delivered here. The unused authenticated record modules and
protected Collective candidate are not enabled by this role. Coordinator
protocol ACK and local native readiness remain separate facts; the current
local host retains its existing installed ownership boundary. No encrypted
RDMA, production registration, pair-grant, or whole distributed request has
been qualified by this source-only candidate.

The overlay modifies no durable provider-store schema. Connection role is not
restored on reconnect. Existing hardware/release evidence is neither fabricated
nor persisted by this increment. Default solo registration and serving follow
the existing paths; additive guards are active only for the opt-in role.
