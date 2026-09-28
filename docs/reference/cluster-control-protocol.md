# Experimental cluster control protocol

> Last updated: 2026-09-17 · commit `605651bb9`

Exact member-role and native-pair public-control shapes on the provider
WebSocket. Member registration is connected to the provider CLI; native-pair
authorization is implemented on the coordinator and mirrored by a Swift codec,
with provider-to-native invocation still pending and the default catalog empty.

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

The provider accepts one acknowledgment before the negotiation's ten-second
deadline and discards that negotiation on reconnect. The acknowledgment proves
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
coordinator's perspective. The current Swift member event dispatcher does not
consume these frames.

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
| Revocation or failure | Closes admission and publishes cancellation; active device holds require both original owner-cleanup observations | `coordinator/registry/native_pair_relay.go`, `Cancel`; `coordinator/registry/verified_pair_lifecycle.go` |
| Relay completion | `WaitControlStopped` joins public-relay workers only; it is not proof of native or lease cleanup | `coordinator/registry/native_pair_types.go`, `WaitControlStopped` |

The [security explanation](../architecture/security/encryption.md#experimental-cluster-pair-authorization)
owns the trust and encryption boundary. The
[routing explanation](../architecture/routing.md#verified-cluster-pair-reservations)
owns reservation and quarantine behavior.
