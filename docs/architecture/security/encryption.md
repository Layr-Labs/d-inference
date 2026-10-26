# Provider Encryption And Privacy

> Last updated: 2026-10-24

This page describes the provider's plaintext boundary, encrypted network traffic
and local cache storage. Backend cryptographic implementation and consumer
transport details are maintained in the external platform, not copied here.

## Context

The provider runs the model, so the prompt must be plaintext inside the
provider process. The coordinator routes, bills, and enforces the request
contract, so it parses the request body in memory. Neither fact can be hidden
by cryptography at interactive latency; the design therefore protects the two
network legs and constrains the endpoints:

- The coordinator handles plaintext only for the life of one request and
  writes none of it to logs or the store (see
  [What the coordinator logs and retains](#what-the-coordinator-logs-and-retains)).
- The provider is the decryption endpoint, and the security claim is about
  *which* provider process holds the decryption key — see
  [`attestation.md`](./attestation.md) and
  [`identity-binding.md`](./identity-binding.md).

Primitive on all three hops: NaCl `box` (X25519 key agreement, XSalsa20-Poly1305
authenticated encryption) from `golang.org/x/crypto/nacl/box` on the
coordinator, `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift` on
the provider, [console-ui/src/lib/encryption.ts](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/console-ui/src/lib/encryption.ts) in the console.

Fresh sender keys do not provide forward secrecy against compromise of a
recipient's private key. The provider's X25519 key lasts for its process
lifetime; that key and the transmitted ephemeral public keys can decrypt
recorded requests from the same lifetime
(`provider-swift/Sources/ProviderCore/ProviderLoop.swift`, `NodeKeyPair.generate`;
[coordinator/internal/e2e/e2e.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/e2e/e2e.go), `SessionKeys`).

Hardened Runtime and debugger restrictions protect the provider process;
they do not guarantee that every prompt, response or model buffer is zeroed
after inference. The `secureZero` and `secureZeroData` helpers in
`provider-swift/Sources/ProviderCore/Security/SecurityHardening.swift` are not
invoked by the inference path. Consumer-facing verification copy therefore
describes process protections. Legacy device-certificate claims use the separate
`mda_verified` proof described in [`attestation.md`](./attestation.md).
[Qualified App Attest serving authorization](../../reference/provider-authorization.md)
is an independent path and never implies legacy MDA/APNs verification.

## Mechanism

The external coordinator decrypts requests transiently for routing/billing, then
re-seals each request to the provider's registered X25519 key with a fresh session
key. The provider decrypts in-process and encrypts response chunks to that session.
Optional consumer sealing terminates at the coordinator; it does not hide content
from either endpoint. See the immutable [platform transport contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/security/encryption.md).

Provider cryptography is implemented by
`provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift` and the provider loop.
Authentication, code identity and encrypted transport are distinct properties.
No inference result is proven correct merely by attesting its executable.

### Provider-bound field minimization

Before serializing and re-sealing an inference request, the shared
`parseInferencePrelude` ([coordinator/api/inference/prelude_parser.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/inference/prelude_parser.go)) runs
`Parser.Parse`, which invokes `stripProviderCallerIdentity` to remove only
caller-supplied top-level `user`, generic `metadata`, `safety_identifier` and
caller `prompt_cache_key`
([coordinator/internal/inference/prelude/request_prelude.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/inference/prelude/request_prelude.go),
[coordinator/internal/inference/prelude/provider_body_privacy.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/inference/prelude/provider_body_privacy.go)).
Direct, queued and retried requests use that prepared body. The original input
bytes remain available in request memory for existing validation; they are not
substituted back into the provider payload.

Nested fields, prompt text, tool/schema content, media and generation controls
remain unchanged. `metadata_details` is a distinct coordinator opt-in, and
coordinator-authored cache scopes and receipt controls retain their existing
account-bound derivation. The coordinator may append its own protocol-0 cache-bust
key after sanitization. Cache scope is a stable account/model pseudonym visible
to the provider, so it permits linkage within that scope; it does not isolate
individual end users sharing one authenticated account. Body-size-derived estimates and activation sampling
can change when unnecessary bytes are removed; authenticated account ownership
and prompt-bearing content do not change.

This does not provide anonymity: prompts, nested content or other caller fields
can still identify a person, and a provider can process requests from multiple
accounts. It remains the plaintext endpoint for requests routed to it.

### What each party can observe

This table is the privacy statement. [../../consumer/privacy-expectations.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/consumer/privacy-expectations.md) and [`../../provider/attestation.md`](../../provider/attestation.md) link to it and do not restate it.

| Data | Consumer | Coordinator | Provider |
|---|---|---|---|
| Prompt and attached media | yes | yes, in memory for the life of the request (parsed for routing, cache affinity, billing); never logged or stored | yes (decryption endpoint) |
| Completion text | yes | yes, in memory while relaying; never logged or stored | yes (generates it) |
| Model, sampling parameters, `stream`, `max_tokens` | yes | yes; stored as non-content request params | yes |
| Token counts, latency, request/trace IDs, selected provider | yes (headers, usage) | yes; stored and logged | own requests only |
| Consumer identity, API key, Privy DID, balance | own | yes | not forwarded as authentication/billing context; caller content can still disclose identity |
| Provider identity: SE public key, chip, model | yes (`X-Provider-*`, `GET /v1/providers/attestation`) | yes | own |
| Provider serial, UDID, APNs token, MDA certificate chain | no | yes (stored) | own |
| Provider X25519 private key, SE private key | no | no | own process / Secure Enclave |
| Other consumers' prompts | no | for requests it processes | only requests routed to that provider; it may serve multiple accounts |

## Provider cache storage

The provider encrypts attention blocks and complete checkpoints before disk I/O
using the existing DBK3 authenticated-encryption format. Keys remain in the
Mac's Secure Enclave/Keychain hierarchy; selecting a different payload volume
does not copy keys there. A dev build has its own installation KEK and Secure
Enclave key (keychain prefix `io.darkbloom.dev`), so it cannot read a production
provider's cache, and the reverse. An ad hoc signed build has no keychain access
group, so it gets no persistent cache key: its SSD stores are refused with
`key_unavailable` unless an ephemeral key is explicitly allowed. For
qualification only, a DEBUG build can instead derive the KEK from an
operator-created private file (`DARKBLOOM_DEBUG_CACHE_KEY_FILE`,
`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDDebugCacheKeyFile.swift`).
That key material sits on disk protected only by file ownership, mode `0600`
and the volume's encryption, not the Secure Enclave; release builds do not
contain this path. Lookup names remain keyed HMACs. Some operational
metadata (sizes, model/layout binding and times) remains visible; the precise
[format and observable fields](../../reference/ssd-kv-cache.md#dbk3-file-format)
are unchanged. TTL checks on reuse, tenant binding and authentication remain in
force. Switching locations leaves earlier ciphertext in its old location; the
new location's maintenance does not sweep the old one or securely erase a disk.
TTL limits ordinary cache reuse, not physical retention: detached or inaccessible
media can retain ciphertext and metadata indefinitely. TTL/LRU deletion requires the
selected volume to be mounted and accessible. Destroying the installation KEK
provides a cryptographic purge for retained encrypted copies; it does not erase
their bytes or visible metadata. A Keychain KEK sealed to a Secure Enclave key
that no longer exists (the attestation key's self-repair re-mints it;
`darkbloom unenroll` deletes it) can never be unwrapped again, so the provider
replaces it with a fresh KEK sealed to the current key, and each store wipes
the files it can no longer read when it next starts
(`provider-swift/Sources/ProviderCore/KVCache/KVCacheKEK.swift`). Only a
ciphertext the current key cannot open triggers this; a failure to reach or use
the key, such as a locked keychain or an access-control refusal, leaves the
entry untouched
(`provider-swift/Sources/ProviderCore/KVCache/SecureEnclaveKeyWrappingService.swift`,
`unwrapError`).
Restart scanning seeds freshness from file modification times, so TTL is not
an anti-rollback guarantee against a malicious disk replaying data and metadata.

`darkbloom cache set --directory` accepts an existing private directory on local,
writable APFS with ownership enabled. External volumes additionally require APFS
encryption. The CLI pins the filesystem UUID in the provider config.
`CacheVolume.inspect` checks suitability at selection and cache construction;
`CacheStorage.validateOpenedDirectory` checks the opened directory's volume UUID,
filesystem flags, ownership and extended ACLs during descriptor-based cache access.
Each access walk also queries current encryption state for the opened volume's
device, so decrypting a selected external volume disables further cache I/O. A missing
mount, replacement filesystem or symlink refuses cache I/O and leaves inference
to recompute. It never creates the missing mount or redirects payloads to another
disk. The persistent write ledger stays on the Mac, including when payloads move.

These are local storage checks, not peripheral attestation. A malicious controller
can impersonate a device, lie about writes or retain ciphertext; an attacker able
to clone the filesystem UUID can defeat the identity pin. Authenticated encryption
rejects altered payloads, but does not prevent deletion, denial of service, traffic
analysis or every replay of still-valid ciphertext. No drive model is certified
safe by these checks. Reformatting a disk does not establish firmware trust.

For a storage recommendation, prefer the Mac's built-in disk; when capacity or
wear requires an external SSD, use a device and enclosure under the operator's
control from a trusted supply chain. This is an operational recommendation
[INFERENCE], not a tested vendor allowlist. Choose endurance against the configured
host-write budget and the manufacturer's specification; host writes are not NAND
writes. Do not attach found, loaned or otherwise untrusted peripherals merely to
run the storage check. The check runs after macOS has enumerated the device.

Evidence consulted on 2026-10-08:

- [Apple's filesystem guide](https://support.apple.com/en-ie/guide/disk-utility/dsku19ed921c/mac)
  identifies APFS encryption and external-storage support.
- [Apple's accessory controls](https://support.apple.com/en-us/102282) let Apple
  silicon laptop users require approval for USB/Thunderbolt accessories. Retain
  approval prompts; that approval is not a firmware-integrity proof.
- [Apple's DMA protections](https://support.apple.com/en-ca/guide/security/seca4960c2b5/web)
  describe IOMMU isolation for peripheral DMA. This is not a disk authentication service.
- [USBESAFE, RAID 2019](https://www.usenix.org/conference/raid2019/presentation/kharraz)
  demonstrates firmware-based USB attacks, which filesystem checks cannot certify away.

Code: `provider-swift/Sources/ProviderCore/KVCacheSSD/CacheVolume.swift`,
`provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift`,
`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDNoFollowIO.swift`.
Operator steps: [cache storage](../../provider/cache-storage.md).

## Two-Mac cluster (experimental)

A [two-Mac cluster](../../provider/two-mac-cluster.md) keeps the same rules
across the Thunderbolt cable:

- **Pairing.** Each Mac's Secure Enclave identity signs the pairing (S17); both
  screens show the same six-digit code and both owners confirm it. The peer's
  pin is stored owner-only (0600), and both Macs verify each other before any
  data-plane key exists. A DEBUG build without the signed build's keychain
  entitlement may keep its Secure Enclave key's opaque handle in an owner-only
  file (`DARKBLOOM_DEBUG_SE_KEY_FILE`, `SecureEnclaveIdentity.debugPersisted`);
  the key itself never leaves the Secure Enclave, and a release build has no
  such path.
- **Cable bytes.** The link control channel (commands, control leases, model
  copies) is keyed by the pairing's edge secret with fresh nonces both ways;
  the data plane (activations, KV hand-offs, cache transfers) is encrypted and
  authenticated with rekeying, and tampered records are refused. The control
  lease runs on a listener and epoch label of its own; no key material crosses
  Macs when control fails over.
  Every installed paired-link text session requires the same keyed worker build
  on both Macs; unsupported or different builds are refused before launch.
  The leader issues fresh session credentials, sends each rank only its own
  credential over its authenticated owner route, and the follower checks the
  epoch and rank before opening its local owner. The native worker verifies
  the certificate and pinned peer. Serving begins only after both workers
  report one matching encrypted, peer-verified data plane. Authenticated
  control/bootstrap status alone cannot satisfy that condition
  (`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterMiMoPrivateImagePolicy.swift`,
  `keysDataPlane`, `followerDataPlaneTrust`;
  `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledSession.swift`,
  `launch`; `libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterDataPlaneLaunch.swift`).
- **Qwen batch records.** Both ranks derive one batch identity from their
  pinned membership epoch, execution plan, lane count and increasing batch
  ordinal. Control records bind the phase, direction and step. Residual records
  also bind the ordered local request identities, fingerprints and frontiers;
  prefill binds its frame bounds. The producer captures these facts before
  forward computation advances its state, and the consumer before receiving.
  The array codec additionally binds shape, dtype, chunk index and byte length.
  Directional record sequences continue across batches and rekeys: replay,
  wrong scope or authentication failure fences the session without a plaintext
  retry (`libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Batch/QwenBatchRecordBinding.swift`,
  `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Resident/QwenResidentRuntime+Batch.swift`,
  `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Transport/CollectiveAuthenticatedRecords.swift`).
- **Model copies.** A Mac accepts a model from its paired Mac only when this
  build's qualification records pin the manifest's aggregate digest, verifies
  every file as it arrives, has its own worker check the staged files before
  the folder is renamed into place, and refuses hard links and unexpected files.
- **Cluster prompt cache at rest.** AES-GCM under a key derived from the
  Secure Enclave-rooted KEK (`provider-swift/Sources/ProviderCore/KVCacheSSD/ClusterPrefixSSDKeyMaterial.swift`),
  passed to ranks on an input pipe (never in an environment), scoped to model,
  plan, rank and Mac.
- **Helpers.** The cluster worker and placement tool ship in
  `Darkbloom.app/Contents/Helpers`, Developer ID signed with hardened runtime
  and network client/server entitlements only
  (`provider-swift/entitlements-cluster-worker.plist`).

## Invariants And Failure Modes

- Do not fall back to plaintext when decryption/authentication fails.
- Bind the registered key to the attested process identity. Preserve fresh
  request session keys and terminal cleanup in the external protocol.
- A missing, replaced or no-longer-encrypted cache volume refuses cache I/O;
  inference may recompute, but must not redirect payloads to another disk.
- Keep cache keys and persistent write accounting on the Mac. Changing the
  payload volume does not reset accounting or erase old ciphertext.
- Do not claim guaranteed buffer zeroization, forward secrecy against recipient
  key compromise, peripheral attestation or correct computation from these controls.

## Related

- [Cache-storage procedure](../../provider/cache-storage.md)
- [Cache format](../../reference/ssd-kv-cache.md)
- [Attestation](attestation.md)
- [Identity binding](identity-binding.md)

### Drained batch setup adoption

The private `batchSetup` command uses the existing authenticated pair-control
channel. The receiver authorizes its saved serving rank 0 and checks unchanged
model, capability, peers, trust, ranks and request limits before publishing a
new setup under the ordinary empty-device lease gate. A compare-and-swap on
the previous full digest refuses an unrelated later choice; retrying the exact
already-selected target is idempotent. The running follower's full setup digest
fences a stale control client before a new native epoch opens. These checks
grant neither coordinator membership nor worker ownership. Sources:
`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterAutomaticBatchSetupTransaction.swift`
and `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterService.swift`.

### Qwen media reservation identity

The optional `qwen35_tp_media_v1` carrier uses at most 16 images, eight videos and
32 MiB of encoded input, with bounded source-raster totals and checked grid/span
arithmetic. Its fingerprint binds all immutable identity and geometry fields but
not encoded-byte presence, so the local payload and peer metadata agree. Rank
zero must separately verify encoded and prepared-patch digests before execution;
a supplied digest is not a decoded-feature authorization. The carrier cannot be
combined with another media contract or request route. Existing record sealing,
worker trust and actual memory admission remain required; this codec change does
not advertise a media-capable runtime or endpoint.

The Qwen27 native media seam sends rank-zero vision features through the
existing authenticated TP collective records. The receiver copies rank-zero
values without a numerical sum, and both ranks verify the same media fingerprint
and recomputed three-axis position identity. Encoded source media is retained
only on its declared rank. `WorkerQwenMediaAdmission` rejects an unsupported
runtime, missing verified data plane, wrong rank payload or mismatched artifact
before reservation. These checks do not grant provider ingress or qualify media
numerics. Source:
`libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/Execution/WorkerQwenMediaAdmission.swift`.

Qwen media transport preserves the typed envelope through owner and peer-link
clock translation. The pair sends encoded inputs to rank 0 only; rank 1 receives
metadata and the same content-bound fingerprint. A caller cancellation or early
resource-release attempt cannot release the owner's encoded alias before the
request has retired. Other model media contracts retain their existing behavior.

Provider Qwen media ingress binds encoded bytes to the loaded artifact, model
configuration, resolved processor, expanded prompt, prepared patches and
three-axis position digest. The bridge checks this binding before submission;
local SDK engines refuse the opaque cluster carrier before allocating KV state.
The process-wide host reservation follows an explicit generation/request owner
through submission and definitive native retirement. Cancellation or HTTP stream
termination is not an encoded-buffer release receipt. No media, token IDs or
prompt content is added to telemetry by this path. The lifetime implementation is
`provider-swift/Sources/ProviderCore/Inference/Distributed/Requests/DistributedQwenMediaLifetime.swift`.
