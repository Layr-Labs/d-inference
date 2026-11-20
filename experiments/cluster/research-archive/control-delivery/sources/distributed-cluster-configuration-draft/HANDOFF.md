# Saved cluster configuration

This overlay implements the first configuration slice from the reviewed distributed-provider delivery plan. `darkbloom cluster configure` saves bounded, pinned setup and an optional `[cluster]` reference in provider TOML. It does not enable distributed mode, start a worker, inspect a model payload, provision SSH trust, advertise capacity or establish readiness. Existing `start` and `local` behavior and default selection are unchanged. The new optional ProviderConfig property defaults to nil and is omitted when absent.

## Integration

Apply `runtime.patch` to the exact main bases in `integration.json`, or copy its 11 listed Swift source/test files. The only existing main files changed are `ProviderConfig.swift` and the subcommand list in `Darkbloom.swift`. ProviderCore already depends on DarkbloomClusterProtocol and TOMLKit; no package manifest change is needed. First integrate the frozen capability package `cluster-runtime-capability-draft-20260915`, manifest `77d910d9f54d9f5219bde6705fe67335493d3d2363e5463f4a15d15f71314f6e`. No shared Runtime, Protocol, process, owner or native source is changed by this overlay.

The command is:

```text
darkbloom cluster configure --input /absolute/setup.json \
  --capability /absolute/capability.json --capability-sha256 LOWERCASE_SHA256 \
  --config /absolute/provider.toml --json
```

`--config` and `--json` are optional; the existing ConfigManager default path is used if no provider path is supplied. Inputs and explicit provider path must be absolute. Configure uses existing ArgumentParser conventions and never calls RuntimeSnapshot discovery, an update banner, ProcessLifecycle replacement/kill, SSH or native code. The capability producer emits canonical bytes; the caller must provide their exact raw SHA. Config selection calls the capability's `selection(planSHA256:)`, without reproducing native Plan math. Capability identity remains metadata until a later installed-worker check.

## Closed configuration shape

`ClusterConfiguration.swift` defines the complete v1 schema. Required top-level keys are `schema`, `clusterID`, `memberID`, `role`, `publicModelID`, `capabilitySHA256`, `selectedPlanSHA256`, `chunkTokens`, `requestTimeoutSeconds`, `peers`, `coordinator`, `trust`, and `tokenizerFiles`. Schema is `darkbloom_cluster_configuration_v1`; role is `leader` or `follower` (rank 0 or 1). Peers are exactly two distinct IDs in rank order. Each names its host/port/user, installed owner and worker paths, model directory, runtime binary SHA and JACCL device. Both binary pins must match this capability's binary pin in the initial compatibility scope. Distinct configured host strings are not proof of distinct machines.

Coordinator is an explicit canonical IPv4 address and port for the current JACCL configuration. No connection or address/device eligibility is asserted. Trust supplies the absolute identity-file and known-hosts paths plus the known-hosts raw SHA. Configure checks current-owned regular nonlinked key metadata and private permissions without reading private key bytes; it checks bounded public known-hosts bytes against the supplied pin. Actual host authentication, key usability and matching host entries remain unverified. Tokenizer files carry unique bounded relative paths, SHA and `tokenizer` or `chatTemplate` purpose. They are saved requirements, not inspected model files. Exact EOS/template/tokenizer-to-model checks remain mandatory in the later model-loading integration.

Pretty configuration JSON is accepted. A bounded scan preserves quoted bytes and checks duplicate/escaped duplicate keys, integer syntax and nesting before Foundation decoding. All keys at every object level and all enums are closed; booleans cannot substitute for integers. Unknown runtime partitions, build pins, role mapping, paths, request bounds or extra enable/environment/capacity/device-gate fields refuse. Capability bytes use the separately frozen canonical codec unchanged.

## Persistence and ownership

Public `ClusterUserPaths()` derives one per-user namespace: `~/.config/darkbloom/clusters` for immutable records and `~/.darkbloom/cluster-device/native-device.lease` for the native gate. The home override is internal fixture-only; setup JSON and CLI cannot select another gate. Existing path components are walked with nofollow directory opens. Final directories must be current-owned and non-writable by other users; configuration/device directories must be private. New directories/files use 0700/0600; unsafe existing modes are refused, never repaired silently.

The same native lease filename and flock contract as ClusterDeviceLease are used. Configure requires the lock and an empty regular single-link private journal throughout publication and pointer update. An active owner or nonempty unresolved journal refuses; no journal is erased or recovered. A solo provider can continue unchanged while inert setup is saved. Actual solo/distributed mutual exclusion on enabling/start is explicitly still required in the next delivery stage. An empty setup gate is not readiness evidence.

Readers use nonblocking nofollow descriptors, positive byte bounds, regular current-owned single-link files and before/after inode/mode/size/time checks. Immutable capability/config files are fsynced then published without replacement using linkat, with exclusive temporary names and directory fsync. Existing content must match exactly. The provider pointer uses the existing `<provider.toml>.lock` convention, reloads under that lock, writes and fsyncs a complete temporary file, rechecks the old content, and atomically renames with post-readback. A failed validation/transform leaves old provider bytes. Later publication durability/readback failures report uncertainty rather than claiming rollback. Staged files are cleaned; completed immutable files can remain unreferenced if the later pointer commit fails.

Provider TOML mutation uses the actual TOMLKit table and changes only `cluster`. Unrelated raw values, unknown extension tables and migration stamps remain semantically intact; first-edit formatting/comments may change. Repeating an identical pointer preserves exact bytes. Existing malformed TOML refuses. With no provider file, a minimal inert `[cluster]` table is created and ordinary decoder defaults remain in force; no hardware-derived defaults are synthesized.

## Verification and remaining work

`python3 run_checks.py --output /absolute/new-private-directory` verifies pinned sources, builds only the small Foundation Protocol/config closure, and runs 9 actual-file groups plus 10 schema/store groups. The tests use fabricated capability metadata and temporary local files; no real private key, model, candidate output, native worker, GPU or network is touched. `checks-final` records all six steps passing with empty stderr. The integration files also pass syntax parsing only. Tests exercise nofollow/link/FIFO/permissions/bounds, lock contention, failed transforms and outside-lock changes, strict schema/identity/type admission, canonical round trips, immutable replay, trust-pin refusal, sticky native journal and no enable/readiness claims.

Five proposed ProviderCore tests cover actual TOML round trips/unknown fields/preservation/refusal and three CLI tests cover parser/dispatch. They have not been typechecked or run against full ProviderCore here; root owns that build and must run them before promotion is qualified. Earlier temporary-path fixture refusals and one redundant `try` compile failure remain under Tests; they were fixture issues, and their history is retained in `history.json`. A full independent source review is pending at freeze; arithmetic read Configuration/Store only and was reassigned before completing the other files.

Next stage must validate installed owner/runtime releases, actual peer trust/identity, model/tokenizer/EOS files and device routes; construct canonical local/remote owner sessions; enforce solo/distributed startup exclusion; derive a fresh epoch and per-host deadlines; retain both real native cleanup and device-release ACKs; and wire the existing provider engine/HTTP request origin. None of those claims follow from saved setup. The frozen delivery-plan body remains unchanged; this handoff records the narrower exact configuration scope and the allowed save-alongside-solo clarification.
