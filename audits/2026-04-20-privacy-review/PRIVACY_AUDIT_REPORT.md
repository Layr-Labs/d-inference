# Dark Bloom Privacy Audit Report

Date: 2026-04-20

Repo reviewed:
- Upstream: `git@github.com:Layr-Labs/d-inference.git`
- Base commit: `86078f892074e85594daa1ca8f30739221cfd9e8`

## Scope

This review compared Dark Bloom's privacy/security model as presented in its theory and white-paper-adjacent materials against the current codebase. The work then moved from semantic review into proof-backed validation for the most concrete suspected privacy failures.

This report is intentionally split between:

1. theory / model observations
2. theory-to-implementation drift
3. verified practical findings backed by tests

It is not a comprehensive cryptographic review of every component, and it is not a statement that every theoretical concern is exploitable today.

## Methodology

The review used three passes:

1. Theory and white-paper review
   - read the published privacy/security story
   - identified implicit assumptions and unstated trust boundaries

2. Code-level semantic audit
   - reviewed the coordinator, provider, attestation, routing, and protected-memory-adjacent paths
   - traced where privacy claims were hard-enforced, optional, softened by config, or not fully wired

3. Proof-backed validation
   - converted the highest-confidence hypotheses into concrete tests inside the repo
   - reran the coordinator-side tests in a current local environment
   - reran the provider-side proof tests in a current local environment after repairing local `pkgconf` / OpenSSL discovery

## Overall Conclusion

Dark Bloom appears to be a serious privacy-improving system, not vapor. The design is directionally coherent and several parts of the architecture show real care. The main issue is not that the privacy story is fabricated; it is that the strongest version of the story is ahead of the current implementation.

The current system reads more like:

`privacy improved under a strict operating model`

than:

`plaintext only exists inside the provider by construction`

The biggest recurring pattern is implementation drift:

- some claims are stronger than live enforcement
- some guarantees depend on strict operator configuration rather than protocol inevitability
- some protected-memory or coordinator-trust claims are cleaner in theory than in active data paths

## Theory-Level Observations

These are not "bugs" in the narrow sense, but they matter because they shape how strong Dark Bloom's privacy claims can honestly be.

### 1. The coordinator remains a meaningful privacy-bearing component

The privacy model is strongest when the coordinator acts as a narrow router with limited content visibility. In practice, the coordinator still has enough visibility into responses, errors, routing state, and provider trust state that it should be treated as part of the privacy boundary, not as a nearly-transparent relay.

### 2. The privacy story depends heavily on deployment posture

Several important properties depend on configuration and operating mode:

- minimum trust floor
- whether weaker provider onboarding paths are allowed
- whether runtime verification evidence is present and enforced
- whether stored provider state is restored and trusted immediately

That means part of the privacy model is operational, not purely cryptographic or protocol-level.

### 3. The protected-memory story needs narrower wording

The architectural narrative around hardened execution and protected memory is stronger than what the code currently demonstrates in all runtime paths. Ordinary process memory, buffering layers, serialization, and temp-file staging still matter. The model should distinguish between:

- the intended "sensitive path"
- the actual set of memory and disk surfaces the implementation uses today

### 4. "Request encryption exists" is not the same as "plaintext fallback is impossible"

The current implementation supports encrypted request paths, but the protocol shape still permits plaintext-compatible request bodies in live provider handling. That difference matters. The stronger claim is not yet warranted.

## Theory-To-Implementation Drift

### 1. Response confidentiality lags request confidentiality

Request-side confidentiality on the main path is materially better than older plaintext assumptions imply. Response-side handling is weaker. The coordinator still processes plaintext response chunks and plaintext error material in ways that are inconsistent with the strongest "provider-only plaintext" story.

### 2. Trust tiers and verification states are softer than the clean narrative suggests

The implementation allows several weaker or partially-restored trust states to become routable under softened configuration or restored state. The gap here is not only conceptual; it shows up in code and in proof-backed tests.

### 3. Runtime verification defaults and restoration behavior are permissive

Newly registered providers can begin from a more trusted/verified posture than the strongest narrative would suggest, and restored state can regrant stronger trust before fresh evidence completes. This is not the same thing as a catastrophic trust bypass, but it is a meaningful softening of the claimed trust boundary.

### 4. Some "protected" handling still leaves ordinary artifacts

The transcription path proves at least one clear case where the active implementation leaves a named `/tmp` artifact after failure. That is a practical gap between the cleanest privacy model and live code behavior.

## Verified Practical Findings

The findings below are backed by concrete tests in this repo. See the appendix for exact file paths, test names, and rerun commands.

### A. Plaintext provider errors leak back through coordinator-facing APIs

Verified across:

- chat completions
- transcription
- image generation

What this means:

- provider-supplied plaintext error strings can reach client responses
- in the chat path, the same plaintext also reaches coordinator logs

Why it matters:

- error paths are part of the privacy boundary
- "normal path is private" is not enough if failure handling reflects sensitive content or prompt-adjacent data

### B. Plaintext response chunks are copied into coordinator-side request channels

The coordinator's chunk handling currently copies plaintext response data into coordinator-side channels before client delivery.

Why it matters:

- this directly contradicts the strongest reading of a coordinator-blind response path
- even if streaming is transient, the coordinator remains able to observe plaintext response material

### C. Plaintext request fallback is still accepted on the provider side

Verified for:

- inference requests
- transcription requests
- image-generation requests

What this means:

- the provider still accepts request bodies without `encrypted_body`
- encryption is not currently enforced as an exclusive input contract

Why it matters:

- this preserves downgrade or regression room
- it weakens any claim that plaintext request delivery is impossible in the live system

### D. Weaker provider trust states can become routable under softened policy

Verified cases include:

- Open Mode provider routability when the global trust floor is lowered to `none`
- valid self-signed provider routability when the floor is lowered to `self_signed`
- immediate hardware-trust restoration from stored state
- immediate stronger routability after restored provider state is applied through the real registration path
- default `RuntimeVerified=true` registration posture before manifest checks

Why it matters:

- the effective privacy/trust boundary is partly controlled by soft configuration and state restoration behavior
- some provider states become usable earlier or more easily than the strongest trust narrative suggests

### E. The transcription path can leave a named `/tmp` artifact after failure

Verified finding:

- a failed transcription request can leave `/tmp/eigeninference-stt-<request_id>.wav` behind

Why it matters:

- this is a concrete protected-path escape to disk-backed temporary storage
- it shows that failure paths deserve the same privacy scrutiny as normal inference handling

## Suggested Remediation Order

### Priority 0

Remove coordinator-side plaintext exposure in:

- response chunk handling
- provider error propagation
- coordinator logging of provider plaintext error material

### Priority 1

Make encrypted request delivery mandatory by contract, not merely preferred by mainline handler behavior.

### Priority 2

Tighten provider trust/routability transitions:

- review default `RuntimeVerified` posture
- review restored-state trust restoration
- review self-signed and Open Mode routability under lowered trust floors

### Priority 3

Audit and remove practical protected-path escapes:

- temp-file staging
- ordinary-memory copies where feasible
- failure-path cleanup gaps

### Priority 4

Narrow claims and documentation where implementation is not yet at the strongest advertised form.

## Closing Note

This report does not claim that Dark Bloom "has no privacy value." The opposite is true: the design has real value and several real privacy-preserving ideas. The problem is that the strongest interpretation of the privacy story is not yet what the current code enforces.

The practical consequence is simple:

- some of the current issues are fixable engineering gaps
- some are trust-model wording gaps
- several now have concrete tests that can be turned into regression coverage once the intended behavior is decided
