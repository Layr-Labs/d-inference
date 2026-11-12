# Verified coordinator pair reservation — private source candidate

This adds a concrete opt-in reservation lifecycle to the existing live coordinator registry. It does not enable distributed routing, transmit a grant, establish traffic keys, approve a native executable, or deploy a coordinator. All work is private; MAIN is unchanged. The 15 new Go test methods are staged and **unexecuted**. Source formatting and pin checks are distinct from compilation or race-test evidence.

## Existing authority and atomic boundary

`Registry.ReserveVerifiedPair([2]*Provider, VerifiedPairRequest)` consumes the exact registered connection objects selected by coordinator code. Both providers pass the existing catalog, dedicated-model, health, privacy, challenge and trait routing chain. Pair admission additionally requires hardware trust, Apple MDA/SE binding, the registration's SE-attested process X25519 key, a fresh connection code proof, a heartbeat younger than 30 seconds, and fresh application evidence from the current approved-release generation. This stricter opt-in gate does not change solo shadow/enforcement policy.

One registry write lock plus deterministic provider locks excludes both ordinary solo commit paths. Neither device is debited if the second fails. Holds cover connection identity, physical serial and SE key, reject already-live aliases of a selected device, and cap retained pairs at 1,024. All existing normal callers pass no pair exception; only validation of the exact held pair can pass its own reservation gate. With no held pair, the new gate takes an immediate allocation-free return.

The returned membership preserves rank order and binds a random UUID epoch, monotonic registry generation, exact provider/device/process/release identities, model, Plan, proposed runtime commitment, suite, preparation deadline and lifetime. A fixed length-delimited domain-separated transcript commits those values. The runtime commitment is explicitly a **proposal**, not coordinator approval of that native code. No inference payload or secret enters this transcript or error messages.

## Lifecycle and ownership

1. `ReserveVerifiedPair` creates a pending preparation hold for at most 30 seconds, within the caller's unchanged lifetime (at most 300 seconds). Existing requests, executing/queued slots, planned model loads and model-command writes must be idle before selection. Idle resident weights may still exist during preparation; they are not treated as unloaded.
2. Each original authenticated connection calls `AcknowledgeVerifiedPairPrepared` with the exact transcript only after actual local solo teardown, canonical device exclusion and runtime verification. It must not start native owners from this acknowledgment. The registry also requires a current authoritative empty solo slot snapshot; that snapshot alone cannot substitute for the local acknowledgment.
3. `CommitVerifiedPairOwners` revalidates both current identities/gates and both prepared observations. This is the coordinator start-authorization linearization point. Any possible delivery after it means owners might start. It never refreshes lifetime. The caller must separately approve the native executable/capability/resource binding and establish fresh authenticated traffic keys before inference-bearing RDMA.
4. `ValidateVerifiedPair` rechecks current membership before each new request/key use; callers also retain/listen to `handle.Done()`. Exact lifetime/freshness timers and connection/trust/release-policy revocation close admission. Request/native ownership remains independent.
5. Pending cancellation, expiry or disconnect releases the pending holds, including a one-sided preparation. The protocol contract forbids owner startup before Commit, so this cannot release active native ownership.
6. Active cancellation, expiry, disconnect or revocation quarantines both physical devices. Timers, EOF and PID absence cannot release them. `ObserveVerifiedPairOwnerReleased` records only the exact original trusted connection's observation of actual native cleanup **and** owner lease-release ACK. Both observations are required before either device is reusable. Wrong transcript, duplicate receipt, disconnected/replacement connection, wrong registry or stale handle is refused. Lost connection/trust requires a separately reviewed administrative fence; there is no arbitrary clear API.

The timer is bounded by existing heartbeat/challenge/application-evidence freshness and the fixed original lifetime. It does not poll or reset the session budget. A normal refresh can update only the corresponding freshness deadline. Explicit revoke hooks cover hard/transient untrust, trust downgrade, challenge failure, cleared code/SIP/application evidence and approved-release generation changes. A transient recovery cannot resurrect an invalidated grant.

## Reader and failure coverage

`SOURCE-MAP.md` traces registry readers and mutation paths. Common liveness gating covers dispatch scans/commits, dispatch plans, public capacity, aliases, warm detection and model-load selection. Warm-pool's separate reason path is explicitly gated. A previously computed load plan rechecks the pair hold when committing its planning entry. Model command writes acquire a short-lived obligation under registry/provider locks and release the locks before IO, preventing pair selection in the selection-to-write gap. Empty `desired_models` revocations remain deliverable. Existing model slot and heartbeat semantics, capacity math, fault history and caches remain unchanged.

There are five small new runtime files, three test files, and narrow changes to eleven existing registry files. No protocol message shape changes: the API has no provider WebSocket sender/receiver yet. This keeps protocol mirroring and grant delivery from being simulated by an unused schema. Future wire handlers must take their exact reader-loop `*Provider`, never a peer-supplied ID, and feed these concrete APIs.

## Required next integration

* A registered control-only cluster-member mode must keep coordinator registration/challenges/heartbeats without loading solo engines or advertising solo serving capacity. Current `StartCommand` acquires solo device exclusion before runtime preparation; `ProcessLifecycle+DeviceExclusion.swift` retains it to process exit. **Do not clear it beneath a live solo process.** Current local distributed serving does not register with the coordinator.
* Local preparation must pause automatic model reconciliation, retire all solo engines, acquire/check the canonical owner boundary and verify the approved native capability/Plan. Empty heartbeat slots are not proof of those actions. Fresh start grants must never survive reconnect.
* The coordinator must approve native executable/capability and transport resource limits, bind fresh native ephemeral keys to these attested connection identities, and deliver grants over the existing authenticated control channel. This slice verifies the provider release, not its proposed child binary. No fixture-supplied key is production membership.
* Quarantine is retained across provider reconnect within this registry instance. Registry restart does not persist this map: fresh local canonical lease/journal checks before any new preparation ACK are mandatory. Administrative recovery and durable coordinator quarantine reconciliation are separate work; this candidate does not claim restart-persistent device release proof.
* Native Ready remains authoritative for real model/geometry/memory admission. Codec cumulative bytes, sealed record expansion, native frame padding and staging allocations must be admitted separately. No extra request slot or memory capacity is manufactured here.

## Review and tests

No compiler was run. `gofmt` parsed/formatted the candidate and source checks verify exact MAIN preimages. Independent review is pending; pipeline is occupied with the native tail/state fixtures. Root remains the immediate source gate.

After a compiler grant, the runner creates a new private workspace from 493 pinned files (eight repository-local Go packages, exact fixture dependencies and this overlay), with no MAIN/cache clone or dependency download. It reuses the reviewed owned-process helper, runs offline with Go 1.25.0, `GOMAXPROCS=2`, `-p 2`, race detection, a 120-second Go test timeout and a 300-second owned parent timeout. It retains source/raw output/execution receipts and checks the 15 new top-level tests completed. The process-wide file cap is 512 MiB to permit Go race archives; diagnostic parsing refuses files above 16 MiB.

```sh
/usr/bin/python3 -B Tests/run.py --repo /Users/developer/DarkbloomDev/d-inference --output /Users/developer/DarkbloomDev/cluster-research/coordinator-verified-pair-checks-1-20260915
```

Run the complete registry regression suite using the same runner with `--all-registry` and a fresh output directory after focused checks pass. No model, external coordinator or remote machine is used. Existing test sources are preserved byte for byte.
