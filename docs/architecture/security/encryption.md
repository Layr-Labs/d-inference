# Provider Encryption And Privacy

> Last updated: 2026-10-09

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
does not copy keys there. Lookup names remain keyed HMACs. Some operational
metadata (sizes, model/layout binding and times) remains visible; the precise
[format and observable fields](../../reference/ssd-kv-cache.md#dbk3-file-format)
are unchanged. TTL checks on reuse, tenant binding and authentication remain in
force. Switching locations leaves earlier ciphertext in its old location; the
new location's maintenance does not sweep the old one or securely erase a disk.
TTL limits ordinary cache reuse, not physical retention: detached or inaccessible
media can retain ciphertext and metadata indefinitely. TTL/LRU deletion requires the
selected volume to be mounted and accessible. Destroying the installation KEK
provides a cryptographic purge for retained encrypted copies; it does not erase
their bytes or visible metadata.
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
