# Experimental cluster control protocol

> Last updated: 2026-10-09

Exact member-role and native-pair public-control shapes on the provider
WebSocket, as staged on the private `kimi/cluster-foundation-20261007`
branch. Member registration and negotiation are implemented end to end
(provider client and coordinator); native-pair authorization is implemented
on the coordinator and mirrored by the Swift codec; the provider member
dispatcher consumes committed starts through the staged member control. The
default native runtime catalog is empty, so every native-pair handler fails
closed; a member registration is still acknowledged, because the acknowledgment
confirms the role and the connection binding only. A provider enters member
mode only through the explicit distributed start opt-in
(`provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift`,
`makeClusterMemberLoop`), and no coordinator selector reserves a pair yet:
`BeginNativePair` (`coordinator/api/native_pair.go`) has no production caller
(see the staging handoff).

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

## Native pair messages

All rows use Go `NativePairMessage` in `coordinator/protocol/native_pair.go`
and Swift `NativePairMessage` in
`provider-swift/Sources/ProviderCore/Protocol/NativePairMessages.swift`.
`IsNativePairInbound` / `IsNativePairOutbound` define the closed directions;
the Swift mirror names them `inboundTypes` / `outboundTypes` from the
coordinator's perspective. The staged member dispatcher
(`NativePairMemberControl` via `CoordinatorClient+NativePair.swift`) consumes
the coordinator→member frames on an accepted member connection only; every
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
| Attachment | Actual accepted request has completed TLS; exact current `cluster_member` connection and nonce | `coordinator/registry/native_pair_connection.go`, `Attach` |
| Selection | Explicit in-process hook chooses two current connections and an approved runtime ID; no public HTTP/provider selection route | `coordinator/api/native_pair.go`, `BeginNativePair` |
| Default | Nil/empty native runtime catalog disables handlers | `coordinator/registry/native_pair_types.go`, `NewNativePairCoordinator` |
| Catalog | At most 64 immutable entries; each binds runtime, model, resources, profile, plan, chips, schedule, limits and expiry | `coordinator/registry/native_pair_approval.go`, `NewNativeRuntimeCatalog` |
| Relay | At most 64 sessions, 16 queued/in-flight frames and 1,048,576 bytes per rank; one control write capped at five seconds and the unchanged membership expiry | `coordinator/registry/native_pair_types.go`; `coordinator/registry/native_pair_relay.go`, `enqueueLocked` / `writeLoop` |
| Revocation or failure | Closes admission and publishes cancellation; active device holds are released by both original owner-cleanup observations | `coordinator/registry/native_pair_relay.go`, `Cancel`; `coordinator/registry/verified_pair_lifecycle.go`, `ObserveVerifiedPairOwnerReleased` |
| Trust loss | A hard or transient untrust, a failed challenge or challenge timeouts at the deroute limit, an attestation or trust-level downgrade, lost SIP verification, a revoked runtime or code proof, and a release-policy generation change each close the grant at once instead of at the next revalidation; a later recovery never revives it. A periodic challenge that verifies does not: the verifier's clear-and-regrant of release evidence leaves the grant open, and validation refuses it while the evidence is absent | `coordinator/registry/attestation_policy.go`, `markUntrusted` / `SetTrustLevel` / `RecordChallengeFailure` / `SetReleasePolicyGeneration`; `coordinator/registry/provider_evidence.go`, `SetAttested` / `SetChallengeVerifiedSIP`; `coordinator/registry/provider_capabilities.go`, `ReconcileAttestedRuntimeCapabilities`; `coordinator/registry/verified_pair_reservation.go`, `validateVerifiedPairLocked` |
| Abandoned quarantine | A member whose original connection left the registry can never deliver its observation. Once every member has either delivered it or departed, the hold is released 40 seconds after the fixed membership expiry: the 30-second preparation limit bounds how far an owner's lifetime deadline can trail the expiry, and the rest covers native cleanup. A member that is still connected and owes its observation is never released by time alone. The relay drops its record of a released session at the next selection | `coordinator/registry/verified_pair_lifecycle.go`, `releaseAbandonedQuarantineLocked`; `coordinator/registry/verified_pair_types.go`, `verifiedPairOwnerRetirementLimit`; `coordinator/registry/native_pair_relay.go`, `removeReleasedSessionsLocked` |
| Relay completion | `WaitControlStopped` joins public-relay workers only; it is not proof of native or lease cleanup | `coordinator/registry/native_pair_types.go`, `WaitControlStopped` |
| Member eligibility | Cluster members and pair-held devices are excluded from ordinary routing, warming and load planning | `coordinator/registry/gate_reason.go`, `GateMemberOnly`/`GatePairReserved`; `model_load_warm.go`, `warmplan` reasons |

The [security explanation](../architecture/security/encryption.md) owns the
trust and encryption boundary. The [routing explanation](../architecture/routing.md)
owns reservation and quarantine behavior.
