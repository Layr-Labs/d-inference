# Experimental cluster control protocol

> Last updated: 2026-10-09

Exact member-role and native-pair public-control shapes on the provider
WebSocket, as staged on the private `kimi/cluster-foundation-20261007`
branch. Member registration and negotiation are implemented end to end
(provider client and coordinator); native-pair authorization is implemented
on the coordinator and mirrored by the Swift codec; a provider whose saved
setup carries a pair approval registers its cluster membership and installs
the member control (see [provider member control](#provider-member-control)).
The default native runtime catalog is empty, so every native-pair handler fails
closed; a member registration is still acknowledged, because the acknowledgment
confirms the role and the connection binding only. A provider enters member
mode only through the explicit distributed start opt-in
(`provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift`,
`makeClusterMemberLoop`). When the operator configures an approval catalog the
coordinator's pair selector reserves pairs by itself (see
[pair formation](#pair-formation)). In this build a real member declines the
preparation, so a reserved pair stops before owners are committed and no pair
serves a request.

## Member registration and acknowledgment

Registration uses the additive fields in
[`register`](protocol-messages.md#register). An omitted or empty role retains
ordinary solo behavior. Member registration sends an empty ordinary model
inventory, a separate cluster inventory and a fresh connection nonce.

| `cluster_member_accepted` field | Type | Rule | Source |
|---|---|---|---|
| `type` | String | Exactly `cluster_member_accepted` | `coordinator/protocol/execution_role.go`, `ClusterMemberAcceptedMessage` |
| `execution_role` | String | Exactly `cluster_member` | `provider-swift/Sources/ProviderCore/Protocol/ProviderExecutionRole.swift`, `ClusterMemberNegotiation.accept` |
| `member_registration_nonce` | String | Exact nonce from this connection's registration | `ClusterMemberNegotiation.accept` |
| `provider_id` | String | Nonempty, at most 128 UTF-8 bytes | `ClusterMemberNegotiation.accept` |

The coordinator queues the acknowledgment as the last step of handling
`register` (`coordinator/api/provider/cluster_member.go`,
`acknowledgeClusterMember`, called from `providerReadLoop` in
`coordinator/api/provider/session.go`): after every step that can refuse the
connection, including native-pair attachment when a runtime catalog is
configured, so a refused member never observes an acceptance. The frame carries
the registry's own record of the connection
(`coordinator/registry/execution_role.go`, `ClusterMemberAcceptance`): the nonce
it registered with and the coordinator-assigned connection ID. A solo
registration is sent nothing. If the acknowledgment cannot be queued the
coordinator closes the socket with status 1013 so the provider negotiates again
on a new connection instead of waiting out its deadline.

The provider accepts one acknowledgment before the negotiation's ten-second
deadline and discards that negotiation on reconnect (`memberRoleFailure` ends
the reconnect loop instead of cycling unacknowledged). The acknowledgment proves
protocol support and connection binding; it is not attestation, runtime approval,
native-owner authorization or serving readiness
(`provider-swift/Sources/ProviderCore/Protocol/ProviderExecutionRole.swift`,
`ClusterMemberNegotiation`).

## Pair formation

Pair formation is off unless the operator sets
[`EIGENINFERENCE_CLUSTER_PAIR_CATALOG`](configuration.md#experimental-cluster-pairs).
The selector (`coordinator/registry/native_pair_formation.go`, `RunFormation`)
then examines attached member connections once a second, and at once when a
member attaches or a held pair is released. It offers two connections to the
reservation below when all of the following hold. It adds no authority: the
reservation repeats every identity, trust, release and idleness check itself.

| Condition | Rule | Source |
|---|---|---|
| Registered membership | Both members registered a `cluster_membership` with the same `cluster_id` and `policy_sha256` and the two distinct ranks. Rank 0 is the leader. A rank claimed by two connections is never resolved by guessing | `formationCandidates` |
| Account | Both connections are linked to the same nonempty account. A member cannot name a peer or another account | `formationCandidates` |
| Approval | Exactly the registered policy: an unrevoked catalog entry whose canonical bytes hash to `policy_sha256`, whose model is in both members' cluster inventories and before whose expiry a full 300-second session fits | `formationApproval` |
| Eligibility | Neither device is held by an earlier pair, and both members pass the pair identity, trust, release-evidence and idleness gates | `coordinator/registry/native_pair_formation.go`, `verifiedPairAdmission`; `coordinator/registry/verified_pair_membership.go`, `verifiedPairMemberLocked` |

A session that stops before owners are committed (a member refused or never
answered the prepare) delays the next attempt for that cluster by 2 seconds,
doubling to at most 60; a committed session resets it. When a session ends at
its fixed lifetime and both owners report cleanup, or when an abandoned
quarantine is released, the same selector forms the next session with a new
epoch. `NativePairCoordinator.Pairs` (`native_pair_view.go`) lists every
registered cluster with its members, state (`waiting`, `preparing`, `active`)
and, while waiting, the reason (`peer_absent`, `no_approval`, `device_held`,
`not_eligible`, `retry_backoff`).

## Provider member control

A member registers a `cluster_membership` only when its saved setup carries a
[pair approval](configuration.md#coordinator-paired-member). The claim is
derived from the installed control, so its `policy_sha256` names exactly the
policy bytes the control requires in a prepare frame
(`provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift`, `serve`;
`provider-swift/Sources/ProviderCore/Coordinator/NativePairMemberInstallation.swift`,
`membership`). Every other member registers none and is never paired.

| Step | Provider rule | Source |
|---|---|---|
| Install | Once, before the first connection, and only when the client registers the control's own claim for this Mac's chip and model. The control outlives reconnects because it owns the member's native-owner obligation | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+NativePair.swift`, `installNativePairMember` |
| Attach | At this connection's `cluster_member_accepted`, only on a `wss` connection that reached its ready state. A member with an installed control that is acknowledged on a plain WebSocket fails its negotiation instead of attaching | `nativePairMemberAccepted` |
| Detach | At every connection boundary, and on a trust status of `untrusted` or `offline` or a failed runtime status. Detaching cancels the session's native work at once | `detachNativePairMember`; `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Inbound.swift`, `handleIncomingFrame` |
| Frames | A `native_pair_` frame is decoded by the closed codec and must carry the attachment's nonce and the next sequence (only `native_pair_cancel` may skip ahead). One that arrives before the acceptance, from another connection or outside that contract ends the connection | `consumeNativePairFrame`; `provider-swift/Sources/ProviderCore/Coordinator/NativePairMemberControl.swift`, `receive` |
| Prepare | The payload's policy must equal the installed policy byte for byte, the start must name this rank, and the frame must leave at most 30 seconds to prepare by this Mac's clock. The member then verifies its installed owner, native executable, metallib and resource library under the device gate and answers `native_pair_prepared` | `provider-swift/Sources/ProviderCore/Coordinator/NativePairMemberSession.swift`, `init` / `runOwned` |
| Committed start | `native_pair_owner_start` launches this Mac's installed owner; the owner's native child drives `native_pair_hello` and `native_pair_confirmation`, and `native_pair_owner_released` is sent only after native cleanup, the owner's lease release and the owner's exit were all observed | `runOwned` / `exchange` |
| Cancel or expiry | Requests native cleanup at once, independently of signing or the socket. An uncommitted session is dropped and the member can prepare again; a committed one that cannot deliver its release stays quarantined in the control, which then refuses every later attachment | `cancel`; `NativePairMemberControl.finished` |

**What a real member does in this build.** The installed owner
(`darkbloom cluster worker-owner --stdio`) serves only the mesh profile of a
session the leader launches itself, and the installed worker refuses every
owner bootstrap attachment
(`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledOwner.swift`,
`servesCommittedNativeStart`). A committed start could therefore not be
honoured and would hold both devices until the members disconnect. The member
declines instead: it answers `native_pair_prepare` with a signed
`native_pair_cancel`, the coordinator never commits, and the selector retries
on its 2-to-60-second backoff. The frames after `native_pair_prepared` are
exercised only against a CPU fixture owner
(`provider-swift/Tests/ClusterMemberFixtureChild`), which proves control flow
and process ownership, never a model, a mesh or hardware trust. A member
accepts no coordinator inference request in any state: it answers 503
`model_unavailable` and reports `draining` with no slots.

## Native pair messages

All rows use Go `NativePairMessage` in `coordinator/protocol/native_pair.go`
and Swift `NativePairMessage` in
`provider-swift/Sources/ProviderCore/Protocol/NativePairMessages.swift`.
`IsNativePairInbound` / `IsNativePairOutbound` define the closed directions;
the Swift mirror names them `inboundTypes` / `outboundTypes` from the
coordinator's perspective. The member dispatcher
(`NativePairMemberControl` via `CoordinatorClient+NativePair.swift`) consumes
the coordinator→member frames on an attached member connection only; every
other connection refuses them with a policy violation.

| Direction | `type` | Public payload | Enforcement |
|---|---|---|---|
| Coordinator → member | `native_pair_prepare` | `DBNPR` version 1, length-prefixed canonical coordinator policy, then canonical native start proposal | `coordinator/registry/native_pair_reservation.go`, `Reserve` |
| Member → coordinator | `native_pair_prepared` | Exact same canonical start | `coordinator/registry/native_pair_handlers.go`, `handleLocked` |
| Coordinator → member | `native_pair_owner_start` | Committed canonical start | `handleLocked`; emitted only after `CommitVerifiedPairOwners` |
| Member → coordinator | `native_pair_hello` | Exact start plus native ephemeral X25519 public key | `coordinator/protocol/native_authorization.go`, `ValidateNativeAuthorizationHello` |
| Coordinator → member | `native_pair_binding` | Ordered pair of validated public hellos | `NativeAuthorizationBinding` |
| Member → coordinator | `native_pair_confirmation` | 32-byte native confirmation MAC | `handleLocked` |
| Coordinator → member | `native_pair_peer_confirmation` | Peer confirmation MAC; the coordinator does not possess its key | `handleLocked` |
| Member → coordinator | `native_pair_owner_released` | `DBNR` version 1, SHA-256 of start, three complete-cleanup flags | `nativePairReleaseReceipt` |
| Both directions | `native_pair_cancel` | `DBNC` version 1 | `handleLocked`; `coordinator/registry/native_pair_relay.go`, `beginCancellationLocked` |

## Shared frame fields

The frame is a flat JSON object. `DecodeNativePairMessage` and
`NativePairMessage.decodePublicFrame` reject duplicate or unknown keys, explicit
nulls, newline bytes and frames larger than 65,536 bytes before accepting a
public-control operation.

| Field | Type | Required | Rule | Source |
|---|---|---|---|---|
| `type` | String | Yes | One of the direction-appropriate types above | `coordinator/protocol/native_pair.go`, `Validate` |
| `version` | UInt8 | Yes | `1` | `Validate` |
| `member_nonce` | String | Yes | Nonzero 32-byte lowercase hex; exact current attachment nonce | `Validate`; `coordinator/registry/native_pair_handlers.go`, `handleLocked` |
| `epoch` | String | Yes | Nonzero 16-byte lowercase hex; exact session epoch | `Validate`; `handleLocked` |
| `generation` | UInt64 | Yes | Positive; exact membership generation | `Validate`; `handleLocked` |
| `sequence` | UInt64 | Yes | Positive, exactly next for the original member connection; exhaustion refuses further use | `handleLocked`; `coordinator/registry/native_pair_relay.go`, `messageLocked` |
| `payload` | String | Yes | Canonical padded base64; decoded size at most 32,768 bytes; type-specific bytes above | `Validate`; `handleLocked` |
| `signature` | String | Member → coordinator | Canonical base64 DER P-256 signature, 8–72 bytes; verified against the member's attested SE key | `Validate`; `nativePairSignatureValid` |
| `prepare_before_unix_nano` | Int64 | Coordinator → member | Fixed membership preparation deadline; member input must omit or equal zero | `messageLocked`; `handleLocked` |
| `expires_at_unix_nano` | Int64 | Coordinator → member | Fixed membership expiry; member input must omit or equal zero | `messageLocked`; `handleLocked` |

`SigningBytes` / `signingBytes` produce length-framed bytes under the dedicated
`darkbloom/coordinator-native-pair/member-message/v1` domain. The SE signs their
SHA-256 digest. The signature field itself is excluded. Traffic secrets,
prompts, activations, diagnostic tails and arbitrary worker JSON are outside
this protocol (`coordinator/protocol/native_pair.go`, `SigningBytes`).

## Authorization and lifecycle limits

| Boundary | Exact rule | Source |
|---|---|---|
| Attachment | Actual accepted request has completed TLS, or it arrived from an operator-listed TLS-terminating proxy that marked it HTTPS (off by default); exact current `cluster_member` connection and nonce | `coordinator/registry/native_pair_connection.go`, `Attach` / `NativePairTransport`; `coordinator/api/provider/member_transport.go`, `memberTransport` |
| Selection | The pair selector, or the explicit in-process hook, chooses two current connections and an approved runtime ID; no public HTTP/provider selection route | `coordinator/registry/native_pair_formation.go`, `RunFormation`; `coordinator/api/native_pair.go`, `BeginNativePair` |
| Default | Nil/empty native runtime catalog disables handlers | `coordinator/registry/native_pair_types.go`, `NewNativePairCoordinator` |
| Catalog | At most 64 immutable entries; each binds runtime, model, resources, profile, plan, chips, schedule, limits and expiry | `coordinator/registry/native_pair_approval.go`, `NewNativeRuntimeCatalog` |
| Relay | At most 64 sessions, 16 queued/in-flight frames and 1,048,576 bytes per rank; one control write capped at five seconds and the unchanged membership expiry | `coordinator/registry/native_pair_types.go`; `coordinator/registry/native_pair_relay.go`, `enqueueLocked` / `writeLoop` |
| Revocation or failure | Closes admission and publishes cancellation; active device holds are released by both original owner-cleanup observations | `coordinator/registry/native_pair_relay.go`, `Cancel`; `coordinator/registry/verified_pair_lifecycle.go`, `ObserveVerifiedPairOwnerReleased` |
| Trust loss | A hard or transient untrust, a failed challenge or challenge timeouts at the deroute limit, an attestation or trust-level downgrade, lost SIP verification, a revoked runtime or code proof, and a release-policy generation change each close the grant at once instead of at the next revalidation; a later recovery never revives it. A periodic challenge that verifies does not: the verifier's clear-and-regrant of release evidence leaves the grant open, and validation refuses it while the evidence is absent | `coordinator/registry/attestation_policy.go`, `markUntrusted` / `SetTrustLevel` / `RecordChallengeFailure` / `SetReleasePolicyGeneration`; `coordinator/registry/provider_evidence.go`, `SetAttested` / `SetChallengeVerifiedSIP`; `coordinator/registry/provider_capabilities.go`, `ReconcileAttestedRuntimeCapabilities`; `coordinator/registry/verified_pair_reservation.go`, `validateVerifiedPairLocked` |
| Abandoned quarantine | A member whose original connection left the registry can never deliver its observation. Once every member has either delivered it or departed, the hold is released 40 seconds after the fixed membership expiry: the 30-second preparation limit bounds how far an owner's lifetime deadline can trail the expiry, and the rest covers native cleanup. A member that is still connected and owes its observation is never released by time alone. The relay drops its record of a released session at the next selection | `coordinator/registry/verified_pair_lifecycle.go`, `releaseAbandonedQuarantineLocked`; `coordinator/registry/verified_pair_types.go`, `verifiedPairOwnerRetirementLimit`; `coordinator/registry/native_pair_relay.go`, `removeReleasedSessionsLocked` |
| Relay completion | `WaitControlStopped` joins public-relay workers only; it is not proof of native or lease cleanup | `coordinator/registry/native_pair_types.go`, `WaitControlStopped` |
| Member eligibility | Cluster members and pair-held devices are excluded from ordinary routing, warming and load planning | `coordinator/registry/gate_reason.go`, `GateMemberOnly`/`GatePairReserved`; `model_load_warm.go`, `warmplan` reasons |
| Model commands | `load_model`, `prefetch_model` and a nonempty `desired_models` are refused for a cluster member or a pair-held device, and a pair is not reserved while one is being written; the empty `desired_models` revoke still passes. A member is offered no desired models, so it only ever receives that empty set | `coordinator/registry/verified_pair_commands.go`, `beginVerifiedPairAwareModelCommand`; `coordinator/registry/model_commands.go`, `SendLoadModel` / `SendPrefetchModel` / `sendDesiredModels` / `DesiredModelsForProvider` |

The [security explanation](../architecture/security/encryption.md) owns the
trust and encryption boundary. The [routing explanation](../architecture/routing.md)
owns reservation and quarantine behavior.
