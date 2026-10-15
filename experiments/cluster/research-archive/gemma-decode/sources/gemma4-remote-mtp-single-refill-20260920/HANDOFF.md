Stage only the explicit D1 synchronous-refill policy first. The default remains
paired grants; D2 refuses the new option. Overlapped lookahead remains min(2,credit),
with the same actual ledger maximum2, buffer5, resource budgets, owner callbacks,
queued-ACK-before-native-execution ordering, both native fences and retirement.
No compiler, native process, GPU or remote operation ran for this package.

Use the optional remote wrapper field `"refillPolicy":"single_for_depth_one_v1"`.
Absent means byte-equivalent old cohort scope and old metadata fields. The new
option is accepted only with local maximumDraftTokens1. It adds two explicit
cohort scope components and reports producerRefillPolicy, maximumProducerRefillGrant1,
maximumProducerLookaheadGrant2. The full result already includes the actual remote
wrapper configuration. Both peers must agree through the original cohort barrier;
no wire opcode, scalar ledger, native owner, model lifetime or resource policy changes.
The per-request pull grammar remains unchanged and accepts the actual count1 grant.

Three exact source overlays modify RemoteMTPInput, PullTarget and RemoteMTPDriver;
one small pure Foundation policy helper is added. The Target edit changes only
its exposed `fill` grant expression. Its overlapped verification grant expression
remains byte-exact. transforms.json records reversible individual replacements so
the separate snapshot batch policy can compose Input/Driver/Target explicitly.
The patch targets actual122-source9c764084 / native5e840fa5; the new projected
closure has123 entries. Original sources and all frozen packages remain untouched.

Why keep lookahead2: one exposed proposal plus two overlapped proposals provide
three positions. A D1 full acceptance consumes its draft and the target bonus
bridge, leaving one ready proposal. Subsequent successful windows can continue
without exposed refill. If both grants were1, that same success consumes both
positions and leaves none ready. An actual retained AsyncMTPProposalLedger control
shows that this alternative cannot start the next verification window. Reducing
both grants would target the reset cost while adding cost to the measured fast
preserved-branch windows.

The actual measured three-request evidence is pinned in phase-evidence.json. It
contains small scalar aggregates derived from target terminal.json, not copied
sidecars. Mean decode is368.248ms/request: exposed refill49.494ms, conditioning
reseed64.164ms, target214.328ms. Six preserved-branch windows had total25.132–26.464ms.
The source step removes one assistant forward from each exposed cold refill;
Gemma4MTPFrozenProposalBranch.build loops exactly grantedCount times and carries
its actual hidden/token into the next batch. It moves that next proposal into the
existing overlapped batch; it does not remove required proposals or claim native
batch-boundary numerical equivalence without a run. No TPS prediction is made.
Even an arithmetic zero-cost elimination of both fill and reseed yields only
about58.9TPS here, below matched solo61.393TPS. Other measured costs still matter.

Eleven staged Foundation controls compile the byte-exact actual ledger, pull record
and mirror from Tests/Inputs. They cover legacy D1/D2, exact option rejection,
credit limits, one exposed/two overlapped scheduling, continued branch reuse,
the all-single starvation counterexample, rejected/bonus-mismatch retirement,
cancel/replayed delivery, and actual mirror seed→queuedACK→completion→pull ordering.
These are scalar controls, not proof of GPU completion or performance. Root may
run under its existing bounded CPU owner (compile60s, execution10s):

```
mkdir qualification-1
swiftc -swift-version 6 -warnings-as-errors Runtime/Gemma4RemoteMTPRefillPolicy.swift Tests/Inputs/AsyncMTPProposalLedger.swift Tests/Inputs/Gemma4MTPPullRecord.swift Tests/Inputs/Gemma4MTPPullMirror.swift Tests/RefillPolicyChecks.swift -o qualification-1/RefillPolicyChecks
qualification-1/RefillPolicyChecks
```

Root must update the private harness's exact wrapper field grammar and cohort scope
rederivation for this option before physical activation; the old strict harness
intentionally refuses it. Keep sample producer maximumDraftTokens2/buffer5 unchanged.
Use fresh same-build solo, legacy remote D1 and explicit single-refill remote D1
P128/O16 captures, compare all64 IDs,4 complete final rows and360 state components,
then matched timing. Preserve dynamic O128 controls and all original physical gates.
Phase timers must show whether exposed fill shrinks without growing proposal drain
or introducing new refill in successful preserved branches. No source-only result
can establish either outcome.

Seed piggyback assessment (not implemented):

- A seed-plus-queued-credit opcode could install the actual fenced capture, issue
  one exact ledger grant, prepare its graph, then send a new seeded-and-queued ACK
  before execution. This removes the separate credit/queued exchange, but the later
  pull/proposals exchange remains necessary to return actual completed proposals.
- Removing both exchanges requires a distinct seed-plus-completed-proposals response
  after actual assistant evaluation and fences. It cannot silently reinterpret seeded
  as generation completion. Both peers need explicit grant position/count, duplicate
  and cancellation handling, and retained target capture through the combined reply.
- The current `seed` message initializes the actual first token and branch. Enqueuing
  work before validated installation, credit acceptance or a matching completed ACK
  would break its ownership/protocol contract. No speculative enqueue is added here.
- Initial-grant piggyback has a smaller protocol/RTT benefit than eliminating the
  exposed second forward and the separately measured snapshot fence cost. Measure
  this independent refill step and the snapshot-batch candidate before that protocol
  change; do not infer pure network cost from the same-target wall measurements.
