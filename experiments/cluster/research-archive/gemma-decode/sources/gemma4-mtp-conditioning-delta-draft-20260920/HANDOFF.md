This is a source-only, pure Foundation prototype for a request-owned conditioning
mirror. It is not linked into any executable. The current full-snapshot path,
initial seven-tensor seed, native admission, floors, observations, control policy,
draft-depth choice, maximum two-proposal grants and five-proposal buffer are unchanged.
No compiler, native process, GPU, remote command or performance test ran here.

The starting audit is `gemma4-mtp-conditioning-delta-audit-20260920`, manifest
`e714fa376bb70d9d2ddb58f3443141ea41a734e296ca03527143b7864036282b`
(the exact manifest pin in source-inputs.json is authoritative). The present
driver also admits O128. Initial frontier is P+1. Reseed is allowed only while
selected outputs < O-1, so its maximum frontier is P+O-3, its maximum gap from
the initial mirror is O-4, and O128 permits a gap124. Accepted windows can keep
the frozen branch alive: a delta is not bounded to one verification width.

Files are split by responsibility: DeltaIdentity derives versioned provenance
and exact chronological ranges; DeltaAllocationPlan derives every live allocation
and compares real allocator results with the existing reservation; MirrorPlan
tracks scalar ordering and retention obligations. Twenty staged Foundation groups
exercise wrap boundaries, identity/replay/refusal, individual allocator calls,
nonlinear overhead/overflow, ACK failure and cancellation cleanup. These are
unexecuted controls, not hardware or runtime qualification.

The new scope must be explicitly opted into and use a new v2 record domain/magic.
The existing authenticated request/epoch/build/artifact/embedding/selected-policy
identity must feed that scope. The pure helper accepts the externally bound scope
digest; it does not establish authentication. Its descriptor binds both snapshot
tuples (scope, branch ordinal, frontier, authoritative seed and hidden dtype), the
append interval and all sliding ranges. This is a provenance identity, not a hash
of KV contents. The eventual codec must reconstruct and compare all ranges and
bind each tensor index, shape, dtype and byte count to the same descriptor. An
encrypted implementation must include that descriptor in its authenticated data.

For F0 -> F1, send hidden [1,1,2816], full K/V [1,2,F1-F0,512] BF16 and sliding K/V
[1,8,F1-F0,256] BF16. Stable hidden dtype1/2 uses2B and dtype3 uses4B, matching the
current transfer plan. The sender must slice the ACTUAL reconciled target capture;
never send rejected verification columns or use assistant-generated KV. Retain
the full prefix and chronological sliding overlap, then append the suffix. Since
d<=124<1024, that entire suffix exists in the current target sliding capture.

Receiver lifetime is the central change. Before dropping a proposal branch,
the original service must retain its four immutable full/sliding K/V arrays.
Drain existing grants/windows, perform the existing native fences and checks,
then retire batch/branch/hidden-chain roots while retaining those request mirror
arrays. Use a new explicit `branchRetiredMirrorRetainedV2` disposition. Never
reinterpret v1's all-roots-retired ACK or manufacture its payload-release proof.
The original proposal ledger still decides grant/window/branch eligibility;
the new pure state helper is not a second request owner or a fence authority.

During update, retain old4KV + received5 + assembled4 =13 roots. Nine new roots
remain in bounded receive staging. The old mirror is separately owned until
assembly, actual C GPU/CPU fences, validation, branch installation and completed
seeded ACK. The receiver advances its base after completed ACK send; the sender
advances only after exact ACK receipt. Any ambiguous ACK, transfer or fence failure
poisons the original request and retains both generations through original owner
cleanup. No replay, full-snapshot fallback or partial-release inference is allowed.
This proof assumes separate allocation roots from the current snapshot path. Four
views into a coalesced full-seed backing would retain that entire backing (including
hidden); such a combination requires a separate backing/liveness proof and new
per-allocation inputs. It cannot silently reuse the13-input enumeration here.
Terminal finish/cancel must fence and release branch AND mirror; cleanup events in
this prototype are only scalar notifications after that real proof, not the proof.

Memory inputs are in memory-inputs.json. Its values are exact logical shape products,
not allocator-rounded memory or observed wire traffic. For P4096/O128, F4097->4221,
FP32 hidden, received tensors total1,534,976B (1.4638671875MiB). All13 roots total
52,382,720B (49.9560546875MiB). The existing12 snapshot terms at max frontier4223
total77,058,048 logical bytes (73.48828125MiB). `admit` independently calls the real
allocation-bound function for the13 roots and verifies every original12 term
against the same function before comparing sums. No linear-rounding assumption,
proposal/head/control borrowing, host allowance discount, or floor reduction occurs.
Actual rounded totals are null until a real allocator is supplied and its receipt
is retained. Source-level logical margin does not itself authorize receiving.

The first implementation must preserve target full-capture/send-pack reservations
and receiver existing host allowance. This prototype saves transfer payload only:
it still constructs a full target snapshot and new full receiver arrays. It does
not establish less target capture work, fewer GPU fences or faster decode.

Minimal future runtime composition, outside this prototype:

1. PullRecord/Input: explicit v2 full-then-delta policy, descriptor and distinct
   mirror-retaining retirement ACK. Keep v1 grammar/default untouched.
2. PullTransferPlan/Snapshot: derive5 bounded tensors, invoke the13-root admission
   before allocation, retain old and new roots, assemble chronological arrays,
   validate evaluated dtype/shape, perform unchanged C fences/checks.
3. PullAssistant/BatchOwner: move four KV roots to the ORIGINAL service mirror
   before branch retirement; install the new branch from that mirror only after
   actual completion. Extend typed ledger retirement semantics at both peers.
4. PullTarget: preserve pending target capture through exact ACK, retain last
   acknowledged base, choose full only initially and delta only on existing reseed
   events. Add bounded scalar base/new frontier, dtype and payload-byte receipts.
5. Qualify actual two-rank reconstruction against full snapshots for F129/F4097,
   d1/2/3/12/124 and a1024-window wrap. Inject postreceive, postconcat-fence and ACK
   failures; prove roots remain held until original cleanup. Then require same-build
   tokens, complete rows and whole KV parity on actual P128 and P4096/O128. Only
   measured phase timing can support a performance claim or default change.

Root-only prospective CPU commands (not executed; use the existing bounded compiler
owner, one60-second compile slot and a10-second run deadline):

```
mkdir qualification-1
swiftc -swift-version 6 -warnings-as-errors Sources/Gemma4MTPDeltaIdentity.swift Sources/Gemma4MTPDeltaAllocationPlan.swift Sources/Gemma4MTPConditioningMirrorPlan.swift Tests/DeltaPlanningChecks.swift -o qualification-1/DeltaPlanningChecks
qualification-1/DeltaPlanningChecks
```

The applicable MAIN AGENTS.md is pinned. Its modularity and post-evaluation error
requirements apply to eventual integration. This package makes no MAIN/vendor or
active-workspace edit and carries no signing, membership or protected-product grant.
