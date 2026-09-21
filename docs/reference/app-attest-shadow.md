# App Attest shadow protocol, machine inventory, and evidence

> Last updated: 2026-09-20 · commit `3b1b6a476`

App Attest shadow collection records stable machine identities, fleet adoption, submitted proofs and receipts alongside legacy verification. Shadow alone changes no routing, rewards or trust. The separately enabled [provider authorization path](provider-authorization.md) uses qualified evidence for MDM-optional serving and rewards. DeviceCheck's separate two-bit API remains deferred.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `EIGENINFERENCE_APP_ATTEST_SHADOW` | `false` | Enables negotiated shadow requests. Disabling it preserves machine inventory, legacy verification, and renewal of existing receipts when credentials are configured. |
| `EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT` | `0` | Stable authenticated-account cohort, integer 0–100. Invalid values exclude all clients. The hard provider floor is `0.9.4`; older, missing, malformed and prerelease versions below that floor never receive Apple operations. |
| `EIGENINFERENCE_APP_ATTEST_QUALIFIED_CODE_HASHES` | unset | Comma-separated `binary_sha256:full_code_directory_sha256` pairs from the same final qualified signed artifact. Only full SHA-256 CodeDirectory measurements (Apple type 2, 32 bytes) can match. Legacy bootstrap only when no durable build row exists and the qualification store is fresh. Missing, malformed or conflicting mappings remain unknown. A durable approval or revocation overrides this value. New gated publications require a durable approval. |
| `EIGENINFERENCE_APP_ATTEST_QUALIFIED_BUILD_HASHES` | unset | Comma-separated immutable binary hashes with completed Mac build/security-transition qualification. This does not override the active release catalog or missing Apple metadata. Legacy bootstrap only; empty remains unknown unless a durable qualification exists. Durable revocation always wins. |
| `EIGENINFERENCE_APP_ATTEST_APP_ID` | `SLDQ2GJ6TL.io.darkbloom.provider` | Expected team prefix and macOS signing identifier. |
| `EIGENINFERENCE_APP_ATTEST_ENVIRONMENT` | `production` | Apple attestation environment; `development` is also supported. |
| `EIGENINFERENCE_APP_ATTEST_RECEIPT_KEY_PATH` | unset | Private server-side ES256 key file with DeviceCheck service authorization, used only for App Attest receipt renewal. Unset disables renewal. |
| `EIGENINFERENCE_APP_ATTEST_RECEIPT_KEY_ID` | unset | Apple key identifier for receipt renewal. Both credential settings are required. |

Code: `coordinator/appattest/service/config.go` (`ConfigFromEnvironment`) and `coordinator/appattest/service/rollout.go` (`appAttestRolloutDecision`). All machines on one authenticated account share the cohort; the percentage is of accounts, not an exact fraction of machines. A provisional machine ID or lost legacy key cannot reroll it. Direct `ServerConfig{}` construction keeps shadow disabled. Serving and MDM-removal controls are specified separately in [provider authorization](provider-authorization.md). Receipt renewal does not generate DCDevice tokens, read or write DeviceCheck bits, or send APNs pushes.

Build qualifications are now managed through the [durable authorization contracts](provider-authorization.md#durable-build-qualification), independently of this wire protocol. `app_attest.qualification.refresh_failed` and `app_attest.release_refresh_failed` count policy refresh failures; these metrics contain no credentials or machine identifiers.

## Wire exchange

New clients advertise `register.app_attest_protocol = 3`; the coordinator also accepts protocols 1 and 2. Older providers receive no unknown frames. A coordinator predating version 3 may ignore the new capability while continuing legacy serving. The registration capability is preserved by both Swift encoders, including `encodeRegisterPreservingRawAttestation`.

The shadow session uses the registry's validated endpoint key, never the original registration field. It requires a canonical 44-character base64 encoding of 32 bytes, rejecting missing/invalid keys and encodings padded with CR/LF before enrollment. Machine inventory remains independent of that readiness check. Code: `coordinator/appattest/service/session.go`.

Frames use `type = "app_attest_shadow"` and nested `payload`. Every request has a random session and expected environment. Versions 2 and 3 carry the negotiated `protocol_version` and an opaque authenticated-account scope.

| Direction | Action | Behavior |
|---|---|---|
| Coordinator → app | `prepare` | Check OS, bundle, signed entitlements, Apple API, and Keychain; load or generate the account-scoped credential. |
| App → coordinator | `ready` | Report support/error and key ID. This is not cryptographic proof. |
| Coordinator → app | `attest` | Persist the enrollment transaction before sending the challenge for an unknown key. |
| App → coordinator | `attestation` | Return complete base64 CBOR and locally derived status. A cached unacknowledged proof also includes its original `enrollment_session`. |
| Coordinator → app | `assert` | Sent only after durable enrollment acceptance. The challenge is encrypted to the actual registered X25519 endpoint. This is the implicit enrollment acknowledgement. |
| App → coordinator | `assertion` | Decrypt using the app's own key, sign the transcript, and return the complete assertion and status. |

Code: `coordinator/protocol/app_attest_shadow.go`, `coordinator/protocol/app_attest_status.go`, and `provider-swift/Sources/ProviderAppAttest/ShadowProtocol.swift`.

All transcript versions encode UTF-8 fields preceded by four-byte big-endian byte lengths, then SHA-256 the result. Version 1 fields are domain `darkbloom.app-attest.shadow.v1`, action, session, environment, key ID, plaintext challenge, and the app-owned X25519 public key. Version 2 changes the domain to `darkbloom.app-attest.shadow.v2` and appends account scope, OS version, OS build, app version, chip, and binary hash in that order. Version 3 uses domain `darkbloom.app-attest.shadow.v3` and additionally appends machine model, physical RAM in GiB, total/performance/efficiency CPU cores and GPU cores as canonical decimal strings, followed by the app’s existing attestation public key. Go and Swift tests pin independent vectors. The coordinator compares these signed app measurements against the registration; version 2 cannot authenticate the added fields.

The app derives status locally. The server never supplies a replacement endpoint key or arbitrary status to sign. Assertion-bound status is authenticated app reporting; it is not an independent Apple certification of the OS version, chip, or binary hash. The prospective policy requires the current Apple launch category and full CodeDirectory SHA-256 measurement, an active catalog match and separately qualified binary/code-hash pair. Missing assertion metadata never falls back to enrollment metadata or an app-reported version.

## Machine inventory and identity

`startMachineInventory` in `coordinator/appattest/service/inventory.go` observes each completed registration, even with shadow disabled or an old client. A separate worker updates liveness once a minute, appends changed observations, and records disconnects. Four concurrent inventory operations are allowed; storage failures are measured and retried. Initial shadow work waits for durable inventory.

`startMachineInventoryReconciler` in `coordinator/appattest/service/inventory_reconcile.go` repairs missed terminal captures on startup and every five seconds. Each attempt shares the four inventory slots, has a two-second deadline, and processes at most 100 rows; errors and locked rows are retried on later ticks. The repair reads durable rows and survives a coordinator restart. The partial index over open sessions avoids scanning closed history.

Reconciliation requires inventory liveness older than five minutes and preserves sessions with a fresh, open `provider_sessions` heartbeat, including connections on another coordinator during a cutover. A known provider-session closure supplies its timestamp and records `disconnect_reason=provider_session`. Otherwise both available liveness streams must be stale; closure is estimated at the latest recorded activity and explicitly labelled `inventory_stale`. A fresh observation can reopen an inferred stale closure using the same machine identity. Confirmed disconnects stay closed, and delayed older observations cannot overwrite newer liveness. Reconciliation appends history and never changes provider routing or accounting records. Code: `coordinator/store/machine_inventory_reconcile.go` and `coordinator/store/postgres_machine_inventory.go`.

| Identity evidence | Association | Meaning |
|---|---|---|
| No usable authenticated identity | Session-local provisional machine UUID | Count explicitly as provisional; do not claim a distinct physical Mac. |
| Authenticated account plus valid endpoint-bound legacy key | Account-scoped key alias → server-assigned UUID | Stable through reconnects. Key-bound identity does not independently prove physical uniqueness. |
| Fresh verified App Attest assertion under the authenticated account | Account-scoped credential alias → UUID | Survives legacy-key rotation without MDM. A claimed credential ID cannot associate a session; revocation-read failure or revoked credentials cannot add an alias. This remains key-bound evidence. |
| Valid Apple MDA serial with verified SE-key freshness binding | Private serial alias → UUID | Hardware-verified association, including safe coalescing of rotated keys. A matching reported serial alone is insufficient. |

Code: `coordinator/store/machine_inventory.go`, `postgres_machine_inventory.go`, `memory_machine_inventory.go`, and `machine_identity_lookup.go`.

Alias merges update the current session-to-machine mapping while retaining `original_machine_id`, account attribution, original evidence/session records, and an explicit merge audit. App Attest credentials are account/machine scoped; canonical lookup recognizes a verified machine merge without replacing an existing key's owner or resetting its counter. No client-supplied UUID selects a machine. An existing credential on the same authenticated account may attempt an encrypted fresh assertion before association; `keyOwnerMatches` is not acceptance of a claimed identity.

A bounded background backfill imports existing provider records. Only previously valid endpoint-bound keys create historical key aliases. Historical MDA booleans and serials do not create hardware-verified mappings. Backfill does not overwrite a live session. Missing historical OS data stays unknown; raw historical proofs discarded before this release cannot be recreated.

The existing serial-based MDM lookup, duplicate-connection handling, fault/quarantine history, routing allowlists, and accounting identifiers remain operational. This release adds the machine inventory used by new evidence and adoption views; it does not rewrite historical payouts or replace live verification. See the [identity design and serial-use inventory](../design/app-attest-release-observability.md).

## Storage and complete evidence archive

PostgreSQL is the durable archive itself, including its normal database backup policy. There is no volatile upload queue or automatic evidence purge. Normal process logs and metric tags contain no raw proofs, certificates, receipts, JWTs, or signing keys.

| Tables | Contents | Code |
|---|---|---|
| `darkbloom_machines`, `darkbloom_machine_aliases`, `darkbloom_machine_merges` | UUIDs, evidence level, private hashed aliases, canonical merges | `coordinator/store/machine_inventory_schema.go` |
| `darkbloom_machine_sessions`, `darkbloom_machine_observations` | Original/current machine attribution, authenticated account, liveness, reported OS/build/hardware, protocol, legacy comparison, refused-frame counts | Same file |
| `app_attest_shadow_events` | Durable stage/outcome/timing observations | Same file |
| `app_attest_evidence`, `app_attest_evidence_blobs` | One record per processed proof submission, original proof field, decoded bytes, checksum, expected transcript, actual reply context, evaluation time, root/verifier/policy/build identifiers, result | `coordinator/store/app_attest_archive.go` |
| `app_attest_shadow_keys` | Verified public keys, account/machine owner binding, environment/app ID, latest counter | `coordinator/store/app_attest_shadow.go` |
| `app_attest_enrollments` | Original enrollment challenge, endpoint, scope, owner, and policy for response-loss recovery | `coordinator/store/app_attest_enrollment.go` |
| `app_attest_receipts`, `app_attest_receipt_blobs`, `app_attest_receipt_jobs` | Complete initial/refreshed receipt versions, bounded HTTP responses, independent verification result, renewal schedule and lease | `coordinator/store/app_attest_receipts.go` |

The archive stores invalid base64 verbatim and preserves invalid, replayed, wrong-session, and late proofs within protocol bounds. The top-level `sha256` and context's `proof_field_sha256` cover the original field's UTF-8 bytes, labelled by `proof_field_checksum_encoding=proof_field_utf8`. Successfully decoded proofs also have `proof_sha256` with `checksum_encoding=base64_decoded_bytes`. `proof_decode_valid=false` identifies malformed base64; partial decoder output is not stored or labelled as a complete decoded proof. Complete attestation CBOR includes every certificate and extension, even fields the verifier does not interpret.

`BeginAppAttestEvidence` writes the full submission before verification. `CompleteAppAttestEvidence` commits the result and accepted key/counter update in one transaction. A failed completion cannot advance a counter or acknowledge enrollment. Interrupted verification initially remains `pending`; `ReconcileAppAttestEvidence` marks rows older than five minutes `interrupted` in bounded locked batches. The original proof remains intact and no counter/key acceptance is synthesized. Identical enrollment is idempotent; replayed assertions remain separate rejected records. Queued proofs are archived as rejected when a shadow session stops or the verifier is busy, subject to the shared storage limit.

`acquireStorage` in `coordinator/appattest/service/storage.go` admits at most four concurrent session storage operations. Normal verification, verifier-busy rejection, disconnect draining, standalone events, and outbound enrollment writes share this limit. Admission is nonblocking; an admitted proof retains its permit through deferred archive completion, and nested observations reuse it. Refused proof submissions increment the session's dropped count and report `archive/storage_busy`; event persistence refusals emit `app_attest.events.storage_failed` with `reason:busy`. Metrics/logs remain available without making another unbounded database call. Inventory and receipt renewal retain their separate worker limits.

Input refused by frame, queue, or storage admission bounds is counted rather than retained without limit. Storage failures pause that connection's shadow exchange and appear in metrics; they do not interrupt inference. The system cannot guarantee recording bytes it never accepts or durably receives during an outage. Re-verification uses the archived context and original evaluation time, never treats a historical assertion as a fresh challenge.

The protocol decoder returns a distinct error for App Attest frames exceeding 48 KiB. The WebSocket read loop increments the negotiated shadow session's atomic refusal counter before discarding the frame; periodic and terminal inventory captures persist that count for the census. It also emits `app_attest.shadow.frames_rejected` with `reason:oversized`, including when no shadow session is negotiated. This path decodes no proof payload, writes no database rows on the read loop, and continues processing normal provider traffic. Other decoder errors do not increment the oversized-shadow counter. Code: `coordinator/protocol/messages.go` and `coordinator/api/provider.go`.

## Receipt verification and renewal

`coordinator/appattest/receipt.go` verifies the PKCS#7 signature and chain against the separately pinned Apple Root CA G3, then validates App ID, key, initial enrollment hash, type, creation freshness, expiry, and renewal fields. Mac field 3 can contain the attestation leaf certificate; its public key must match the verified credential. Duplicate ASN.1 fields and malformed metadata fail closed. Receipt errors are observational and do not remove legacy trust.

`coordinator/appattest/service/receipt_worker.go` leases at most one due job per second when dedicated credentials are configured, including when new shadow exchanges are disabled. It sends the previous receipt to the environment-specific Apple endpoint, verifies the response, retains every recorded version, and advances the job only for a verified successor or a separately validated historical recovery input. Failures retain the previous usable receipt and back off. HTTP bodies are bounded to 64 KiB; an oversized response has an explicit outcome. Raw server authentication material is never archived. Overdue jobs remain visible while credentials are unconfigured. Mac production receipt renewal is a separate qualification from initial local receipt verification.

Apple's [receipt contract](https://developer.apple.com/documentation/devicecheck/assessing-fraud-risk) specifies `Authorization: <JWT>` for this endpoint, including its curl example. The worker sends that raw ES256 JWT; the linked APNs guide supplies the JWT generation procedure. The receipt's approximate recent key-count metric is not a permanent machine identifier or an automatic fraud verdict.

`VerifyReceipt` keeps Apple’s five-minute creation-time requirement. A cached enrollment receipt that fails only freshness can pass `ReceiptForRenewal`, which still checks the Apple receipt chain, identity, key, client hash and expiration. Its outcome is `renewal_required`, never `verified`. The worker exchanges it for a fresh `RECEIPT`; HTTP responses must pass the strict fresh validator. Initial `ATTEST` receipts require the exact enrollment hash. Apple renewed risk receipts bind the app and attested key, and can carry a lossy text representation in field 4; the verifier never treats that as a nonce binding. Fresh signature/chain, app/key, creation time, expiration and risk fields remain mandatory, and receipt types cannot substitute for one another. `QueueAppAttestReceiptRecovery` seeds missing jobs for old `receipt_creation_time` records only when the original attestation was accepted and its credential exists. Recovery appends a new receipt version and leaves the original failure untouched. The worker claims one job per second with a two-minute cross-coordinator lease; failures retain the last usable receipt and retry later.

`startAppAttestMaintenance` runs independently of the shadow switch and credentials, once per minute with at most 100 records per batch. See `coordinator/appattest/service/maintenance.go` and `coordinator/store/app_attest_maintenance.go`.

## Bounds and credential lifecycle

| Boundary | Behavior |
|---|---|
| Initial spread | Random 0–29 seconds after inventory is ready. |
| Shadow processing | One worker and two queued replies per connection; four verification operations and four shared session storage permits globally, including rejection and cleanup paths. |
| Protocol | 48 KiB frame, 32 KiB decoded proof; bounded CBOR and status fields. |
| Response/storage | 90-second response deadline; two-second handling budget, with a separate two-second budget for deferred archive completion. Standalone events and enrollment writes each have a two-second storage timeout. |
| Assertions | Every ten minutes after success; a fresh encrypted challenge after reconnect or recovery. A failure immediately supersedes the last prospective verdict. |
| Session recovery | Transient failures retry after one minute, then five minutes, then hourly. Every attempt gets a new session/nonce and reloads durable acceptance/counters. Successful assertions reset backoff. Permanent crypto/policy rejections stop; cancellation stops retries. Code: `coordinator/appattest/service/retry.go`. |
| Apple callbacks | 25-second waiter deadline. The actual uncancellable Apple operation retains admission until its callback arrives; retries receive `busy` in the meantime. A token fences duplicate late callbacks from unlocking a newer operation. A pre-cancelled call does not acquire admission. Code: `AppleOperationGate.swift` and `AppleAppAttestService.swift` in `provider-swift/Sources/ProviderAppAttest/`. |
| Attestation retries | At most three attempts, 2/8-second waits, only for service unavailable, using the same key/hash. |
| Key generation | Per-key one-hour replacement cooldown plus five generations per coordinator/environment per hour across account scopes, persisted before calling Apple. |
| Lost enrollment response | Keychain temporarily retains proof and original status; retry uses a server-persisted, same-owner transaction up to 24 hours old. Its stored protocol selects the original transcript; a version 3 upgrade can recover an old version 2 enrollment, but the following fresh assertion must use the new protocol. Expired pending proof is replaced under the generation budget. |
| Acknowledgement | An assertion request follows durable enrollment acceptance; the successful local assertion clears the cached enrollment proof. |
| Cancellation | Connection generation prevents late delivery into a different session. |

Code: `AppAttestShadowClient.swift`, `CallbackDeadline.swift`, `AppleAppAttestService.swift`, and `coordinator/appattest/service/context.go`. Keychain items remain nonsynchronizing and device-local; private App Attest keys remain with Apple's service.

## Prospective authorization

`coordinator/appattest/authorization.go` (`EvaluateAuthorization`) evaluates the
future policy without MDM/APNs inputs or registry mutations. It is not wired as
a serving gate in this release. `coordinator/appattest/service/policy.go`
records its versioned outcome after each durably accepted assertion; failed
exchanges supersede the previous verdict.

| Condition | Missing evidence | Negative evidence |
|---|---|---|
| Account, machine, credential, connection, endpoint, app and environment binding | `unknown` | `ineligible` on a binding mismatch |
| Complete admitted evidence for this connection | `unknown` when a proof was refused or its initial archive write failed | No readiness claim can erase a recorded archive gap |
| Protocol 3 existing verification key matches the verified registration key | `unknown` if unavailable/unbound | `ineligible` on substitution; keeps existing model/runtime signatures linked to the verified app |
| Protocol 3 static hardware claims match registration | `unknown` if absent/unbound | `ineligible` for a model, chip, RAM or CPU/GPU mismatch |
| Verified credential, endpoint custody and current assertion | `unknown`; assertions expire after `AssertionFreshness = 15 * time.Minute` | Existing crypto verifier rejects invalid signatures/replay |
| Current Apple launch category and exact code measurement | `unknown` for absent metadata, unsupported algorithm or missing qualified mapping; no enrollment fallback | `ineligible` for non-Developer-ID launch, a code-hash mismatch, or a present bundle-version mismatch. A missing bundle version is allowed only with the required matching code measurement. |
| Active release catalog plus qualified immutable build | `unknown` when unavailable/unqualified | `ineligible` for a known catalog mismatch |
| Credential revocation | `unknown` when storage is unavailable | `ineligible` when revoked |
| Verified unexpired receipt, risk metric and configured renewal | `unknown` | Renewal overdue by 24 hours remains `unknown`, not a zero risk metric |

`eligible` receives an expiry bounded by assertion freshness, receipt expiration
and renewal freshness. It is a prospective observation, not a portable cached
lease. A future serving gate must reevaluate current connection, revocation and
release policy at dispatch. Raw risk counts are evidence, not an invented fraud
threshold or physical-device identifier. `app_attest_key_revocations` and
`RevokeAppAttestKey` persist account-scoped, idempotent revocations without
changing legacy trust. The [rollout runbook](../operations/app-attest-rollout.md)
lists qualification and retirement gates.

### macOS SDK and signed code measurements

A controlled physical macOS 27 test of the same probe with SDK 26.5 and SDK 27.0 found that only the SDK 27 build returned the launch category and code measurement. With CDhash opt-in, its assertions carried `apple_cd_hash_type_01` as one byte (`2`) and `apple_cd_hash_hash_01` as the full 32-byte SHA-256 CodeDirectory digest. That digest exactly matched `codesign -d --verbose=4` `CandidateCDHashFull sha256`; it is neither the truncated 20-byte `CDHash` nor the SHA-256 of the entire signed executable. No bundle-version extension was present. These are observed wire semantics requiring qualification on the final artifact and supported OS builds, not a promise of an undocumented future format.

`coordinator/appattest/code_measurement.go` parses the bounded signed fields and exposes only the observed type-2 SHA-256 format for matching. `coordinator/appattest/service/build_policy.go` requires an explicit qualified mapping for the reported binary hash; the independently loaded release catalog also pins that binary hash and version. The policy never accepts a code hash supplied in ordinary client status as Apple's measurement. Unknown algorithms remain recorded but cannot qualify. Assertions and enrollment observations retain `attested_code_directory_type` and `attested_code_directory_hash`; only the current assertion feeds prospective authorization. Parsed measurements are also committed atomically into the proof decision details. Verified OS/build status is recorded even when readiness storage fails or the key is revoked; only identity alias attachment depends on a known non-revoked credential. SDK 26 builds remain safe shadow clients and stay unknown for replacement readiness.


## Dashboard and telemetry

The private admin dashboard at `/app-attest` queries the read replica. It distinguishes 24-hour/7-day windows, distinct accounts, stable machine records, provisional/key-bound/hardware-verified identities, connection sessions, latest OS, first recorded macOS 27+ observation, fresh assertions, stage outcomes, latency, and archive/receipt health. The machine list displays the latest 200 identities; aggregate census counts cover the whole window. Evidence history is paginated at 100 submissions per page.

Machine drill-downs download complete evidence/context and receipt history. Both the global Basic Auth proxy and the raw-download route authenticate access; downloads have `private, no-store` caching. A missing schema or unavailable query renders an explicit unavailable section, without false zeroes or hiding other working sections.

Code: `admin-ui/src/lib/queries/app-attest.ts`, `admin-ui/src/lib/queries/app-attest-readiness.ts`, and `admin-ui/src/app/app-attest/page.tsx`. Readiness groups the newest observed connection per machine/version, shows all recent identities with offline cohorts separately, checks verdict expiration, current policy version and revocation, and lists missing/rejected conditions. Expired or missing expiry contributes `verdict_expired_or_missing`; a retired policy contributes `policy_version_stale`. A current revocation immediately contributes `credential_revoked` to the reasons table, even before another assertion; repeated reasons count each machine once. An earlier connection’s success never qualifies its replacement. These are recent evaluations; catalog or qualification changes require another evaluation.

Metrics include `app_attest.shadow.events`, `app_attest.shadow.duration_ms`, `app_attest.shadow.metadata`, `app_attest.inventory.recorded`, `app_attest.inventory.failed`, `app_attest.archive.received`, `app_attest.archive.completed`, `app_attest.events.storage_failed`, and receipt/archive failure counters. `app_attest.receipt.configured` reports whether both credential settings are present; `app_attest.maintenance.interrupted`, `app_attest.maintenance.receipt_recovery` and `app_attest.maintenance.failed` expose reconciliation. Machine/account IDs appear in private records and logs, not high-cardinality metric tags. Logs complement the durable census rather than defining the denominator.

`app_attest.inventory.reconciled` counts repaired terminal records; `app_attest.inventory.reconcile_failed` distinguishes contention from storage failures.

## Packaging and qualification

The existing CLI, app identity, user LaunchAgent, APNs grants, and deployment floor remain intact. `scripts/prepare-app-attest-entitlements.py` adds only profile-authorized CDhash opt-in and any explicitly granted environment entitlement. An old profile keeps legacy signing. The real adapter requires the full signed app in the supported user context and checks actual API availability.

The [initial physical report](../reports/2026-09-14-app-attest-macos27-validation.md) records macOS 27 acceptance and its limits. The [version 2 validation](../reports/2026-09-14-app-attest-inventory-validation.md) records earlier integration evidence; [0.9.4 recovery qualification](../reports/2026-09-14-app-attest-recovery-validation.md) records the current candidate and its limits. Final notarization, install/update and APNs/MDM regressions across the supported OS fleet, security-transition negatives, and production rollout remain separate release gates.

The [0.9.3 disconnect investigation](../reports/2026-09-14-app-attest-release-disconnects.md)
records the optimized callback-timer crash and production pause. App Attest
deadlines and retry delays use the non-generic nanoseconds sleep workaround.
The packaged `runtime-smoke` command exercises callback completion and deadline
expiry without calling Apple; the release workflow requires its
`app-attest-callback-runtime-smoke: ok` marker before publishing.

Run focused Go tests under `-race`, including App Attest, receipts, inventory and archive contracts. PostgreSQL tests require a disposable `DATABASE_URL`; the harness truncates tables. Swift tests cover all three transcripts, account isolation, response loss, deadlines, and both registration encoders. Admin query integration tests use `APP_ATTEST_TEST_DATABASE_URL` on the designated disposable local database. No production state is mutated by these tests.
