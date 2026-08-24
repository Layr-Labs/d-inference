# 061 — Exact simultaneous CBv2 prompt forking

**Date:** 2026-08-24
**Status:** implemented behind a default-off experiment
**Scope:** simultaneous text requests on the exact Qwen3.5/3.6 hybrid-state path

## 1. Decision

The smallest exact simultaneous-request optimization is a live boundary fork,
not another durable cache:

1. inspect unscheduled CBv2 rows before `SchedulerV2.plan()`;
2. group compatible token-identical or shared-prefix prompts;
3. run the common prefix on one leader row;
4. stop the leader at a finalized prompt boundary;
5. clone its complete attention K/V and recurrent state into request-owned
   follower rows;
6. let every row consume at least one ordinary prompt token and then sample and
   decode independently.

The experiment is off unless `CBv2PromptForkConfig(enabled: true)` is supplied
or `DARKBLOOM_CBV2_PROMPT_FORK` is one of `1`, `true`, `yes`, or `on`.
Unsupported model, layout, or backend combinations fail closed.

This is exact work deletion. It does not alter weights, routing, logits,
sampling, or generated-token order. It also does not change the locked cold
single-request denominator: it helps only when requests overlap in both time
and prompt tokens.

## 2. Ownership and transaction audit

`EngineLoopV2` owns three distinct classes of request state:

- `SchedulerV2` owns the logical token cursor, status, pending-sample count,
  cancellation marker, and admission reservations.
- `EngineLoopV2.kvStates` owns one backend-registered K/V wrapper array per
  live request.
- `EngineLoopV2.recurrentStates` owns one
  `CBv2RecurrentRequestState` per live hybrid-model request.

Recurrent execution is transactional:

```text
bind visible generation
  -> model stages every recurrent layer
  -> evaluate closes the binding and creates a pending generation
  -> asyncEval materializes K/V + recurrent roots + logits
  -> finalize commits or rolls back that exact generation
```

Scheduler planning advances `numComputedTokens` optimistically, so that cursor
alone is not a safe fork signal. The implementation calls
`preparePromptForkCohorts()` and `forkReadyPromptForkCohorts()` only after the
previous in-flight step has finalized. A leader is forkable only when:

- its committed cursor equals the clamped boundary;
- it has no pending sample and no generated token;
- its K/V rows all report that same complete offset; and
- its recurrent owner has no open binding or speculative generation.

Followers are parked at zero progress in `waiting`. Parking is separate from
stream backpressure, so a consumer resume cannot expose an uninitialized row.
The engine publishes K/V and recurrent owners before clearing the parked bit.

## 3. Why the boundary leaves one prompt token

For prompt length `P`, identical prompts fork at `P - 1`. Shared prompts fork
at their longest common prefix, clamped to at most the shortest prompt minus
one.

Leaving one prompt token is the minimal way to avoid another shared object:

- no frontier-logit snapshot is required;
- no sampled token or sampler transaction is inherited;
- each follower runs its own final shared or divergent prompt token;
- ordinary CBv2 sampling, stop handling, RNG ownership, and decode apply
  unchanged.

With chunked prefill, “compute once” means every common-prefix token executes
in one leader row. The prefix may still span several normal chunk graph
launches; the optimization does not bypass CBv2's chunk-size or token-budget
rules.

## 4. Exact clone primitives

The implementation adds two explicit, independently reusable seams.

### K/V

`CBv2ExactKVForkingBackend` captures a `CBv2KVForkSnapshot` and constructs a
new registered sequence state from it. `CBv2ContiguousKVBackend` is the first
conforming backend.

It accepts only storage-owning full-attention rows with:

- one row per declared layer;
- rank-4 `[1, kvHeads, tokens, headDim]` K and V;
- a uniform positive absolute offset; and
- a destination `maxLength` that contains the boundary.

Each follower gets new contiguous K/V buffers. Later append, rollback, or
release of the donor or any follower cannot alter another row. Registration
uses the backend's existing atomic reservation check, including destination
growth slack. Malformed public snapshots throw before reaching row
preconditions.

### Recurrent state

`CBv2RecurrentStateSnapshot` validates every declared conv/SSM layer, shape,
dtype, and fixed byte count. Restoring creates a new
`CBv2RecurrentRequestState` and detached initial arrays. The ordinary
bind/evaluate/commit/rollback protocol remains unchanged after restoration.

`supportsPromptStateForking` is separate from
`supportsExactStatePrefixReuse`. A model must explicitly prove arbitrary
ordinary-boundary forking; durable full-prompt cache support does not imply it.
Qwen3.5/3.6 opts in because its CBv2 layer list contains the ten complete
full-attention K/V owners and its recurrent specification contains all thirty
GDN conv/SSM owners.

## 5. Cohort planning and fail-closed scope

Planning runs before each ordinary scheduler plan. It first groups identical
prompts, then greedily forms deepest compatible shared-prefix cohorts.
Running prefill rows precede waiters in leader selection, allowing a
near-simultaneous arrival to join work that has started but has not crossed the
boundary.

Rows must have equal priority and cache salt. The current exact path also
requires:

- request-level prefix reuse enabled;
- text-only input;
- no external position state;
- no adopted prefix plan or exact cached frontier;
- no generated or pending sampled token;
- an explicit model capability;
- a nonempty, all-full, storage-owning layer layout; and
- a `CBv2ExactKVForkingBackend`.

Multimodal rows, windowed/shared K/V layouts, paged K/V, unknown models, and
rows already using durable prefix adoption remain on the established path.

## 6. Cancellation, failure, and accounting

Follower publication is transactional per row:

1. reserve its skipped token count in `AdmissionV2`;
2. construct and register independent K/V;
3. restore independent recurrent state;
4. verify combined backend plus recurrent bytes against the hard capacity;
5. publish both owners; and
6. activate the scheduler record at the fork cursor.

Any failure releases the partial state, returns its reservation, and unparks
that follower for cold prefill. Other followers may still fork.

Cancellation behavior is explicit:

- a follower cancelled before the boundary is removed without disturbing the
  leader or siblings;
- if the last follower leaves, the leader's clamp is removed;
- a leader cancelled before the boundary unparks every live follower for cold
  prefill;
- after publication, every row follows ordinary independent cancellation,
  in-flight rollback, deferred release, and admission cleanup.

`CBv2PromptForkActivity` reports cohorts formed/forked/abandoned, forked and
fallback follower rows, common-prefix token cells saved, and the conservative
logical K/V plus recurrent bytes installed in followers. Admission charges
every row's future ownership even where MLX can temporarily retain immutable
graph roots.

## 7. Regression matrix

The added tests cover:

| Arm | Required proof |
|---|---|
| default off | absent/unrecognized environment values do not activate |
| planner | deepest prefix, priority isolation, and cache-salt isolation |
| K/V primitive | two restored rows advance/release independently; accounting returns to zero |
| malformed K/V | public shape mismatch throws with no registration leak |
| recurrent primitive | two restored owners diverge without donor/sibling mutation |
| B2 identical | candidate checksums equal cold control; saved token cells equal `P - 1` |
| B4 shared prefix | three followers fork; all surviving checksums equal cold controls |
| follower leaves after fork | one row cancels while leader and siblings finish; K/V and admission return to zero |
| follower cancels before fork | cohort dissolves safely with no cloned state |
| leader cancels before fork | follower falls back to cold prefill with control checksum |
| Qwen capability | exact durable reuse and live prompt forking are independently asserted |

The fixture is deliberately hybrid: its recurrent scalar is the exact sum of
tokens consumed, and its greedy logits depend on that scalar. Missing,
off-by-one, or aliased recurrent restoration changes the checksum immediately.

## 8. Aggregate ceiling

Let:

- `B` be simultaneous rows;
- `P` be prompt tokens per row;
- `S` be the forked common-prefix tokens; and
- `D` be post-fork per-row token-equivalent work.

Ignoring clone and scheduling overhead, baseline aggregate work is

```text
W0 = B(P + D)
```

and prompt-fork work is

```text
Wfork = S + B(P - S + D)
      = B(P + D) - (B - 1)S.
```

The aggregate work ceiling is therefore

```text
speedup <= B(P + D) / [B(P + D) - (B - 1)S].
```

For prefill alone (`D = 0`) and overlap fraction `s = S/P`:

```text
speedup <= B / [B - (B - 1)s].
```

| overlap `s` | B2 ceiling | B4 ceiling |
|---:|---:|---:|
| 50% | 1.333x | 1.600x |
| 60% | 1.429x | 1.818x |
| 75% | 1.600x | 2.286x |
| 80% | 1.667x | **2.500x** |
| 90% | 1.818x | 3.077x |
| 100% limit | 2.000x | 4.000x |

The implemented identical-prompt boundary uses `S = P - 1`, giving

```text
B2: 2P / (P + 1)
B4: 4P / (P + 3).
```

At `P = 8192`, those prefill-work ceilings are approximately `1.9998x` and
`3.9985x`. Decode work, clone bandwidth, reduced one-row GPU utilization, and
normal scheduler overhead lower wall-clock speedup. These are aggregate
token-cell ceilings, not a real-checkpoint latency claim.

## 9. Patch handoff

The agent identity can push the root repository but receives HTTP 403 from
`Layr-Labs/mlx-swift-lm`. A root gitlink to the local commits would therefore
be unfetchable in a clean clone.

Apply the ordered patches instead:

```text
research/qwen36-prefill/patches/060-exact-cbv2-prefix-boundary.patch
research/qwen36-prefill/patches/061-cbv2-simultaneous-prompt-fork.patch
research/qwen36-prefill/patches/061-provider-exact-prefix-wiring.patch
```

The prompt-fork patch applies inside `libs/mlx-swift-lm` after the exact-state
`060` patch. The provider wiring patch applies at the root and remains specific
to the durable cache experiment; live prompt forking is controlled by its own
default-off engine configuration.
