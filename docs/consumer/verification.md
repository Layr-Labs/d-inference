# Verifying provider attestation

> Last updated: 2026-09-23 · commit `0e6c98345`

How a consumer reads the coordinator's trust verdict about the provider that
served a request, and what that verdict does and does not prove. The verdict is
computed by the coordinator; consumers receive its result, never the
raw Apple certificates or receipts behind it. Public legacy verification keys
remain visible and can link successive public sessions.

[App Attest shadow measurements](../reference/app-attest-shadow.md) do not authorize serving. When separately enabled and qualified, the [App Attest serving path](../reference/provider-authorization.md) appears as `app_attest_authorized` and an exclusive Unix-seconds `authorization_expires_at` deadline in the public listing. The existing `trust_level`, MDM and MDA fields still describe legacy evidence; they are not rewritten to represent App Attest. The listing has its existing short cache window and is diagnostic, not a reusable serving credential.

An App Attest grant also depends on a fresh [durable build qualification](../reference/provider-authorization.md#durable-build-qualification). Withdrawing it fences old qualification generations; cached download metadata or a prior successful signature cannot grant new dispatch. Independently valid legacy verification remains a separate serving path.

For a provider owner, **Verified via legacy authorization** is a serving-method
label, not permission to remove Darkbloom MDM. The owner dashboard points to
`darkbloom unenroll`, which requires fresh connection-bound App Attest
authorization and explicit coordinator removal readiness before offering the
migration option.

Local profile-inventory authentication during `darkbloom unenroll` only identifies the Darkbloom enrollment for user-guided removal. It does not verify or extend serving authorization; the [provider procedure](../provider/attestation.md#app-attest-without-darkbloom-mdm) explains the separate coordinator readiness requirement.

## Read verification in chat and network stats

Open a response's verification panel to see **Verified via App Attest**,
**Verified via legacy authorization**, both methods, or an unavailable/pending
verdict. A legacy `self_signed` field can coexist with a valid App Attest grant.
The panel shows verification **at dispatch**; an old response makes no claim
about the machine's current permission to serve. Missing snapshots on older
messages display unavailable rather than inferring a method from `attested`.

Public network counts, directory method filters and proof details show **verification at the source snapshot**. They include App Attest-only providers and count dual-path connections once in the total and in both breakdowns. The snapshot age remains visible, including when stale. An expired lease in an old snapshot does not prove the coordinator stopped renewing it; the browser does not turn those historical App Attest counts into zero. Refresh to obtain another observation.

The owner provider dashboard and MDM-removal controls remain live views: stale or expired authorization cannot enable serving or removal. Connections are distinct from known unique machine inventory; reported macOS 27 adoption is separate. Missing verdicts are unknown and use the available-verdict denominator. See the [fields and freshness rules](../reference/api-contracts.md#verification-presentation-contract).

The proof view explains coordinator-side Apple chain/key enrollment, current
assertion, receipt policy and qualified-build checks. Detailed certificate and
receipt data are not published; missing timestamps are unavailable. Your browser
does not independently validate Apple evidence. App Attest does not certify RAM
or chip reports, guarantee memory wiping, prove computation correctness, or
remove the coordinator as a plaintext endpoint; see
[encryption boundaries](../architecture/security/encryption.md).

## Public attestation endpoint

An Apple API error can leave an App Attest-only provider pending while the coordinator retries. Retry activity is not successful verification: only an unexpired coordinator-derived authorization permits that path to serve. Independently valid legacy authorization retains its own evidence requirements.

An enrolled App Attest key can remain pending while Apple renews an initial receipt into a verified risk receipt or supplies its first risk metric. The coordinator requests fresh assertions on a bounded schedule during that wait. Neither an unverified receipt nor a retry is serving authorization; only a current authorized verdict marks the provider verified.

A signed proof can also be eligible while the coordinator is still restoring
the current account-scoped machine identity or checking the final runtime and
storage gates. The `eligible` policy observation describes that proof, not a
lease. `GET /v1/me/providers` and the current connection's authorization
status show whether this Mac can actually serve. A later clean assertion can
recover from an earlier recorded archive refusal; the refused attempt remains
in audit counts and never grants permission by itself.

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

`GET /v1/providers/attestation` needs no authentication and returns
`{"providers": [...]}` (`handleProviderAttestation`, `coordinator/api/provider.go`).
Private-only connections are excluded before the response enters its shared
cache; their owners still see them through authenticated `GET /v1/me/providers`.
Each entry carries:

| Field | Meaning |
|---|---|
| `provider_id` | Opaque connection ID; also returned per response as `X-Provider-Id` |
| `chip_name`, `hardware_model`, `memory_gb`, `gpu_cores`, `models[]` | Hardware class and served models |
| `trust_level` | `none`, `self_signed`, or `hardware` (below) |
| `status` | `online`, `offline`, `untrusted`, … |
| `secure_enclave`, `sip_enabled`, `secure_boot_enabled`, `authenticated_root_enabled`, `system_volume_hash`? | Latest posture the coordinator verified |
| `se_public_key` | The provider's persistent legacy Secure Enclave P-256 public key (base64); permits linking public sessions, is not a private key or the App Attest credential |
| `mdm_verified` | `true` exactly when the live connection holds `hardware` |
| `acme_verified` | Deprecated, always `false`; kept on the wire for shipped decoders |
| `mda_verified`, `mda_os_version`?, `mda_sepos_version`? | Apple Managed Device Attestation result, surfaced only while the connection holds `hardware` |

Deliberately absent: hardware serial number, UDID, APNs device token, the raw
Apple MDA certificate chain (its leaf embeds serial and UDID in signed OIDs,
so publishing it would disclose them even with the JSON fields removed), and
the `code_attested` flag.

## What the levels mean

| `trust_level` | What it tells you |
|---|---|
| `hardware` | Apple's MDM subsystem on that Mac confirmed SIP and full Secure Boot in agreement with the provider's Secure-Enclave-signed attestation. MDM `SecurityInfo` is the only path to this level; the MDA certificate chain is not required for it |
| `self_signed` | The Secure-Enclave-signed attestation verified and the provider is passing the coordinator's periodic challenge, but there is no MDM confirmation yet |
| `none` | No verified attestation |

The grant and loss conditions for each level are tabulated in
[`../architecture/security/attestation.md#trust-levels`](../architecture/security/attestation.md#trust-levels);
the challenge cadence is in [Layer 2](../architecture/security/attestation.md#layer-2--periodic-challenge)
and the routing freshness window is
[`challengeFreshnessMaxAge`](../architecture/routing.md#challenge-freshness).

The coordinator verifies `status_signature` by reconstructing the exact signed
bytes (`coordinator/attestation/attestation.go`, `VerifyStatusSignature`). The
provider's canonical encoder matches mixed-case hash-map key ordering and
U+2028/U+2029 escaping to that format; see [Layer 2](../architecture/security/attestation.md#layer-2--periodic-challenge).
This byte compatibility changes neither the trust levels nor the public fields,
routing gates or per-response signals described here.

`mda_verified: true` adds that Apple issued a Managed Device Attestation whose
certificate chain verifies to the Apple Enterprise Attestation Root CA and
binds the provider's SE key (or serial) — proof of *which* genuine Apple device
holds the key. It is a flag on top of `hardware`, not a level, and it does not
gate routing ([Flag — Apple Managed Device Attestation](../architecture/security/attestation.md#flag--apple-managed-device-attestation)).

Public routing applies the coordinator's trust floor (`MinTrustLevel`, set by
[`EIGENINFERENCE_MIN_TRUST`](../reference/configuration.md#routing-admission-and-ttft))
plus every privacy gate (encrypted response chunks, coordinator-verified SIP,
required privacy capabilities, code identity once enforced), so a request you
send without self-routing is served only by a provider that passes all of them
([`../architecture/security/attestation.md`](../architecture/security/attestation.md#routing-gate)).

## Per-response signals

Once a provider has been committed to your request, the coordinator writes
these headers (`writeCommittedProviderHeaders`,
`coordinator/api/response_metadata.go`):

| Header | Value |
|---|---|
| `X-Provider-Id` | Connection ID; join with the endpoint above |
| `X-Provider-Trust-Level` | `none` / `self_signed` / `hardware` |
| `X-Provider-Attested` | `true` / `false` |
| `X-Provider-Encrypted` | `true` when the provider has a registered X25519 key (the mandatory coordinator → provider hop) |
| `X-Provider-Secure-Enclave` | `true` / `false` |
| `X-Provider-Mda-Verified` | `true`, present only when true |
| `X-Provider-Chip`, `X-Provider-Model` | Hardware class |
| `X-Attestation-Se-Public-Key` | The provider's SE P-256 public key (base64) |
| `X-Eigen-Sealed`, `X-Eigen-Sealed-Kid` | Present when you sealed the request; the body is sealed to your ephemeral key ([`../architecture/security/encryption.md`](../architecture/security/encryption.md)) |

The headers are the coordinator's assertion over TLS. Pin the provider identity
by comparing `X-Attestation-Se-Public-Key` with `se_public_key` from the public
endpoint across requests.

Successful bodies may also carry optional **provider-generated** `se_signature`
and `response_hash`; the coordinator forwards them rather than signing the
consumer response itself. The native provider's `computeResponseAttestation`
hashes UTF-8 `requestId:completionTokens:responseBody` and signs the UTF-8 hex
hash using its `AttestationSigner`
(`provider-swift/Sources/ProviderCore/Security/SecurityHardening.swift`).
`responseBody` is the producer's accumulated content, reasoning and encoded
tool calls, not the final coordinator JSON or SSE representation
(`ProviderLoop.handleInferenceRequest`, `provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift`).

Field presence alone is not verification. Verify the signature against the
provided hash and the matching provider key; do not compare the hash with a
reserialized consumer response or only its visible answer. Streaming signature
metadata retains the response's ID; the distinct coordinator request ID is
available in `X-Inference-Job-ID` (and opt-in `metadata.job_id`). See the
[SSE contract](../reference/api-contracts.md#sse-framing). These optional signals
do not create a new hardware-trust level or establish account/attestation
qualification in an ephemeral test environment.

Pre-commit errors (validation, capacity, availability) have no selected provider
and therefore no `X-Provider-*` headers.

### Reading the fields from an SDK

OpenAI SDKs generally hide custom headers. Send `metadata_details: true` in the
request body (or the header `X-Darkbloom-Metadata-Details: true`) on
`POST /v1/chat/completions` and the same values arrive in the JSON `metadata`
object: `provider_id`, `provider_attested`, `provider_trust_level`,
`provider_encrypted`, `provider_chip`, `provider_machine_model`,
`provider_secure_enclave`, `provider_mda_verified`,
`attestation_se_public_key`, `timing`, and `location`
(`coordinator/api/types/types.go`, `ChatCompletionMetadata`). `location` is
region/country-level GeoIP only — no city, coordinates, lookup source, or IP.
See [`../reference/api-contracts.md`](../reference/api-contracts.md).

## Code identity

The strongest production gate is APNs code-identity attestation: proof that the
process holding the provider's decryption key is the genuine, team-signed
Darkbloom binary. It is not a consumer-visible field, but once enforcement is
switched on (`APNS_ENFORCE_AFTER`) a provider without it is excluded from
private-text routing, so a served response implies it passed. See
[`../design/apns-code-attestation.md`](../design/apns-code-attestation.md) and
[`../architecture/security/attestation.md`](../architecture/security/attestation.md#flag--apns-code-identity).

A coordinator reconnect still requires a fresh process-possession challenge before
private routing. Recorded code-verified continuity can avoid another Apple push
for the same process; it does not grant hardware trust or bypass verification.
See [APNs code identity](../architecture/security/attestation.md#flag--apns-code-identity).

## Related

- [`privacy-expectations.md`](./privacy-expectations.md) — what each party can see.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — sealing your request and reading a sealed response.
- [`../provider/attestation.md`](../provider/attestation.md) — the same verdicts from the operator's side.
