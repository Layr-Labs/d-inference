# Native-pair B reader/failure/cleanup map

| Seam | Existing reader or authority | B behavior |
| --- | --- | --- |
| immutable role + nonce | member RegisterMessage / Registry.Register / provider read loop | retains nonce with private immutable role; no model/capacity mutation |
| physical ownership | verified_pair_reservation.go / verified_pair_lifecycle.go | real Reserve/Acknowledge/Commit/Validate/Cancel/ObserveReleased; no alternate ownership table |
| current trust | verified_pair_membership.go + role-aware routing eligibility | exact current Provider, SE/process key, release generation, MDM, code/SIP/freshness and model requirements retained |
| ordinary routing/load | existing V2 hooks and member execution_role.go | unchanged; held devices and control-only role still excluded |
| WebSocket ingress | api/provider.go / protocol/messages.go | closed bounded decode, exact retained attachment; nil catalog or unregistered native frame refused |
| registration/attestation | existing ACK, verifyProviderAttestation, challenge and APNs loops | ACK remains protocol-only; TLS attachment is not attestation |
| server configuration | api/server_config.go / NewServer | only explicit prevalidated immutable native catalog; environment default nil |
| public output | registry/provider_writer.go | existing priority serialized writer; bounded extra queue; no secret/native diagnostic output |
| failure/reconnect | read error before slow store stamp + deferred Detach | exact pending grant cancelled or active quarantined; replacement object cannot release it |
| expiry/revocation | Registry Done + native catalog revocation | stops public writers, preserves actual physical hold; fixed original deadlines |
| server close | Server.Close / NativePairCoordinator.Close | stops known grants and rejects concurrent pending publication; no fabricated release |
| release | signed DBNR observation + original connection | requires native cleanup, real lease ACK and transport completion; Registry rechecks current cleanup authority |
| native transcript | qualified A Common/Start/Hello/Binding | exact independent public vector; no private/shared keys enter coordinator |

No additions mutate BackendCapacity.Slots, CurrentModel, WarmModels,
pendingModelLoads, MDM/code evidence, release generation, solo admission counters
or store records. The only Provider field added is the registration nonce. Its
readers are Attach and the construction initializer; heartbeats/models updates
cannot replace it. The connection/session maps are protected by their own mutex;
that mutex never performs network writes. Registry lock ordering remains the
existing Registry-then-provider order. Pending Registry reservation runs outside
the coordinator mutex and is revalidated before publication; callbacks, entropy
acquisition and actual writes do not run while that mutex is held.
