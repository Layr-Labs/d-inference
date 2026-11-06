# Authenticated RDMA record codec — private source candidate

This implements only the bounded record primitive requested after the trusted-peer source audit. **It is uncompiled and unexecuted at this freeze.** No MAIN, native, coordinator, installed configuration, transport, or model changes were made. No production encryption or membership qualification is claimed.

The audit is frozen separately at `rdma-trusted-peer-security-audit-20260915`, manifest `d7bd312c52c84a30bf67acd2f984ca150d4305ff3b2f46783188a2352f65ea03`. It specifies the missing authorization/key-establishment, transport and resource-admission integration.

## Four small runtime files

The proposed `DarkbloomClusterSecurity` module imports only Foundation and CryptoKit. Its Package delta adds one independent library/target. Nothing uses it automatically.

- `ClusterRecordTypes.swift`: closed value types/errors, canonical immutable binding/context, configured hard limits and value-only status.
- `ClusterRecordFraming.swift`: fixed 24-byte public prefix, strict bounded parsing and 96-bit nonce construction.
- `ClusterRecordState.swift`: directional key derivation, one operation ticket, counters/budgets and cancellation/publication lock.
- `ClusterAuthenticatedRecordChannel.swift`: standard Data-based CryptoKit AES-GCM seal/open and fail-closed lifecycle.

Public entry:

```swift
ClusterAuthenticatedRecordChannel(
    sessionKey: SymmetricKey,          // exactly 256 bits; fresh for this epoch
    binding: ClusterRecordBinding,    // epoch, Plan, membership transcript, suite
    localRank: Int,                    // exactly 0 or 1
    limits: ClusterRecordLimits)
channel.seal(plaintext, context: locallyExpectedContext)
channel.open(sealedRecord, expecting: locallyExpectedContext)
channel.invalidate()
```

`ClusterRecordContext` requires an explicit setup scope (nil request) for confirmation/load/readiness types, and a nonzero request UUID for every inference/retirement type. `expectationSHA256` is a digest of canonical phase/geometry/frontier metadata; do not put inference payload in AAD. There are no arbitrary context dictionaries, duplicate fields, payload callbacks, log hooks, reset, cloning or plaintext fallback APIs.

The caller owns key freshness and authorization. Constructing a second sending channel with the same secret/binding/rank would reuse its initial nonce and is forbidden. This primitive cannot discover that external misuse. The future session/key-establishment owner must admit one channel per direction/epoch and never resume/recreate it with the same key context. A caller-supplied membership hash is not proof of membership.

## Crypto and record contract

- Supplied secret: exactly 256 bits. HKDF-SHA256 salt contains an explicit versioned domain, epoch, Plan hash, authenticated-membership transcript hash, suite and agreed limits. Directional HKDF info has a separate domain and both source/destination ranks. No coordinator, disk or SSH key is reused.
- Wire: `DBRD` magic, version, suite, source rank/direction, closed record type, UInt64 sequence (big endian), UInt32 plaintext length, four zero reserved bytes, ciphertext, 16-byte tag. Prefix size is always 24; total is plaintext + 40 bytes. Unknown version/suite/type/reserved values are refused. No nonce is transmitted.
- Nonce: four fixed domain/version/direction bytes followed by the session-wide 64-bit sequence, big endian. Sequences start at zero, include setup traffic and never reset per request. Keys differ by direction. Configured record limits are far below wraparound.
- AAD: separate domain + canonical binding + agreed limits + explicit request scope/UUID/type + expected phase/geometry metadata digest + exact public prefix. Fixed-width encodings avoid concatenation ambiguity. Inference bytes never enter AAD or error/status strings.
- The default hard ceilings are 16 MiB per record, 1,048,576 records and 4 GiB cumulative plaintext per direction. Callers should set smaller admitted bounds. These are conservative codec limits, not an audited application-wide GCM security budget or a memory/capacity grant. Reaching a limit refuses the next operation and permanently invalidates the channel; it does not wrap, rekey, or refresh deadlines.
- `boundedRecordByteCount(fromPrefix:maximumPlaintextBytes:)` is explicitly **unauthenticated, cap-only** parsing for a two-step bounded receive. It never authorizes consumption. The caller must receive the full bounded record, call authenticated `open`, and invalidate/fence on framing or transport failure. No allocation is based on an unchecked UInt32.

## Ordering and failure semantics

Only one operation may be outstanding on a channel. A short lock installs an immutable operation ticket and key/AAD snapshot. CryptoKit runs outside the lock. Invalidation takes only the lock, drops channel key references and prevents a completed operation from publishing if invalidation won the final check. The stack-local copied key can persist until synchronous CryptoKit returns; immediate key erasure or preemption is not claimed.

Concurrent use, malformed input, invalid tag/context, replay/skip, budget exhaustion or a crypto failure poisons the channel. A racing reject does not clear another operation's outstanding ticket. The owning operation closes its ticket; receive counters/bytes advance only after authenticated open and the final active/ticket check. `finish()` is the publication linearization point. Invalidation can follow it before the caller receives the returned Data; the caller still applies its unchanged deadline and request-state checks.

No native state, leases, model captures, stream timers or cancellation callbacks are held here. Invalidating this codec does not manufacture cancellation ACK, native retirement, owner release, or empty device journals. Existing independent process fencing must continue without waiting for crypto; actual ownership remains until its real cleanup proof.

## Source fixtures and bounded runner

Eight groups are staged against the exact four runtime files: setup/request round trips; configuration/scope refusal; every header/cipher/tag region; truncation/unknown/reserved/overflowing length; wrong key/epoch/Plan/membership/limits/request/type/geometry/direction; replay/skip and usage caps; and deterministic concurrent/invalidation publication using the exact internal lock/ticket helper. An eighth interoperability group checks independently assembled canonical binding/context/header/AAD/HKDF key/nonce and exact AES-GCM seal/open for both directions. `Tests/generate_vectors.py` uses Python stdlib HMAC/HKDF-SHA256 plus the existing OpenSSL EVP AES-GCM (ctypes), never Swift/CryptoKit output. Generation already ran using OpenSSL 3.6.4, with only public fixture keys; the Swift interoperability check remains unexecuted. The helper checks do not add runtime test callbacks and do not claim to interrupt a live CryptoKit primitive. Received plaintext remains unavailable on authentication failure.

After the root grants the compiler slot:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-codec-draft-20260915/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-checks-1-20260915
```

The runner uses a fresh output/cache, direct Swift 6 warnings-as-errors, macOS 14 deployment target, `-j 2`, 60-second compiler and 10-second CPU fixture bounds. It preserves stdout/stderr, argv, PID/group/reap receipt, errors and pre/post source pins. Diagnostic output is checked against 1 MiB per stream after termination (not a claim of streaming backpressure). The owned-process helper is byte-exact from the reviewed Gemma Foundation runner correction. No SwiftPM, MLX, payload, network or native process is involved. Final compilation and all eight groups must actually pass before promotion.

## Required later work

1. Coordinator-verified/routable pair authorization and fresh per-native key establishment, independently bound to both current identities/connections and the native epoch.
2. Complete use by all inference-bearing RDMA paths, including readiness/header/ACKs; no bypass or downgrade. AEAD authenticates before reconstructed residual/model consumption.
3. Include cumulative per-direction byte/record limits in request admission and session lifetime/rotation budgets. Refuse or drain before admitting a known worst-case request envelope that cannot fit; do not discover predictable exhaustion mid-request. Sixteen 27B P8192/C512 residual streams alone are approximately 1.34 GB (1.25 GiB), plus controls, below the current 4 GiB cap; future expert routing requires its own envelope. Codec status exposes counters, but performs no request admission.
4. Named host/native ciphertext/plaintext staging budgets, charged at Ready/reserve/live checks; retain real send/receive fences and actual cleanup. Current Data APIs can copy and are deliberately used for the first correctness slice. New Apple RawSpan in-place API availability/ABI and buffer ownership need a separate audit; no macOS 26.2 availability or zero-copy claim here.
5. Actual-machine numerical/tamper/replay/resource/cleanup qualification and matched encrypted timing. CPU codec success alone is not secure production RDMA.
