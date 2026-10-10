# Design: placement from detected hardware

> 2026-10-09, branch `work/placement`. Second edition: the planner, the
> layout, the estimator and their checks are built; what is not built is in
> "Status" at the end. "Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max
> (128 GB).

Requirement (owner, 2026-10-09): the distributed system detects what hardware
and memory is on each device and splits accordingly. It is universal, not
written per machine or per pair. A model is never refused for memory when some
placement on the cluster fits.

## What is fixed today, and where

| Decision | Where it is fixed | By whom |
|---|---|---|
| Which cut a pair runs | `selectedPlanSHA256` in the saved setup (`provider-swift/Sources/ProviderCore/Config/ClusterConfiguration.swift`), turned into `--stage-cut` by `DistributedInstalledPlan` | Typed into the setup file; found by a measurement sweep |
| Which cuts exist | `QwenResidentModelDefinition.supportedCuts` (9B: four typed values; 27B: the structural rule), at most 16 partitions in a capability record | Code, per model |
| Which Mac is rank 0 | `ClusterConfiguration.localRank`: the leader is rank 0 | The setup's `role` |
| Which mode | `generationMode` in the saved setup, the pipeline when absent | Typed |
| Whether a stage fits | `QwenDenseStageLoadPolicy` at load time, one stage on one Mac | Detected, but only to refuse |
| Time budgets | `DistributedInstalledPairServingTable`, one row per model | Typed from one pair's measurements |
| Approval | `plan_sha256` and `allowed_chips` per approval (coordinator, private repository) | Typed |

Nothing connects the memory the gate detects to the choice of cut, rank order
or mode. On another pair the typed cut either wastes the larger Mac or is
refused on the smaller one.

## Shape

Four values and one function, all free of MLX and of any table of machines:

```
device profile (per Mac, detected)  ─┐
model layout   (per artifact, derived) ─┼─▶ planner ─▶ ranked candidates, or a refusal
speed estimate (per device and model) ─┘
```

They live in a new target `DarkbloomClusterPlacement` in
`libs/darkbloom-cluster` (Foundation only, macOS 14) so that the provider,
which does not link the MLX runtime, can run the planner itself. The parts
that must touch the system or an artifact live in `DarkbloomClusterRuntime`
under `Models/Placement/` and fill those values:

| Value | Filled by | From |
|---|---|---|
| `ClusterDeviceProfile` | `ClusterDeviceProfileSampler` (runtime) | `sysctl`, the gate's own sampler and policy, Metal |
| `ClusterModelLayout` | `ClusterModelLayoutBuilder` (placement) with a family's `ClusterPlacementFamily` | safetensors headers and `config.json`, through the family's stage plan |
| `ClusterSpeedEstimate` | a stage probe (runtime, GPU), a cache, or a labelled prior | measurement on this Mac |

## 1. Device profile: what one Mac detects about itself

Read at run time, every time; nothing is looked up by machine name.

| Field | Source | Used for |
|---|---|---|
| `chip` | `machdep.cpu.brand_string` | Speed cache key; shown to the operator. Never a planning input |
| `performanceCores`, `efficiencyCores` | `hw.perflevel0.physicalcpu`, `hw.perflevel1.physicalcpu` | Shown; prior |
| `gpuCores` | IORegistry `gpu-core-count` of the accelerator, when published | Shown; prior |
| `osVersion`, `osBuild` | `ProcessInfo.operatingSystemVersion`, `kern.osversion` | Speed cache key |
| `physicalMemoryBytes` | `hw.memsize` (the gate's own read) | Hard ceiling |
| `gpuRecommendedWorkingSetBytes`, `gpuMaximumBufferBytes` | Metal device, as MLX reports it | A stage beyond the working set is ranked last; a tensor beyond the buffer limit cannot load |
| `allocatorLimitBytes` | the MLX allocator's limit in a fresh process | The load gate's second comparison |
| `memory` | **the gate's own observation and decision** (below) | Fit now |
| `power` | AC, low-power mode, thermal state: the three things `QwenResidentResourceEnvironment.require` refuses on | A device that would be refused at request time is reported before a plan is made |

Codable, about 1 KB, schema `darkbloom_cluster_device_profile_v1`. It carries
no host name, serial number, address, user name or path. A member is named in
it only by the label the setup already uses for it.

### Memory: one formula, the gate's

The profile's `memory` block is produced by calling
`QwenDenseStageLoadResources.observeOS()` and
`QwenDenseStageLoadPolicy.decide(_:requiredBytes:purpose:now:)` and copying
the decision's numbers. The planner holds no copy of the formula and no copy
of its constants; the floor, the headroom and the scratch allowance travel in
the profile as the gate reported them.

The gate's decision depends on the requirement only through comparisons, so
it reduces to numbers a planner can carry:

```
admits(R)  ⇔  judged ∧ actualFree ≥ minimumTrulyFree ∧ R ≤ physical
              ∧ admissibleNow ≥ max(floor, R)
```

A check compiles the gate's policy file beside the planner and requires, over
a sweep of observations and requirements, that `profile.memory.admits(R)`
equals `decide(...).admitted`. If the gate's rule changes (the MiMo work asks
for a change to the 32 GiB cache cap), the profile changes with it and the
planner follows without an edit; the check fails if the reduction above stops
being exact.

A Mac's memory is three parts with three different remedies, and the profile
keeps them apart; the output never adds them up:

| Part | In the record | Remedy |
|---|---|---|
| Free pages | `actualFreeBytes` | None needed |
| File cache above the kernel's minimum | `fileCacheAboveReserveBytes` | None needed: the kernel gives it up without touching an application. The gate counts part of it (`countedFileCacheBytes`) |
| File cache the kernel keeps as its minimum | `fileCacheReserveBytes` (the 10/27 term, as the gate computed it) | None short of a restart. Measured on this pair: the kernel gave cache up freely down to this figure and then compressed applications within a second. It is never promised |
| Applications | `anonymousBytes` | Closing them turns their memory into free pages |
| Wired and compressed | `wiredBytes`, `compressorBytes` | None in a session |

From these, every requirement on every device gets one of five answers:

| Answer | Condition | What the output says |
|---|---|---|
| **fits now** | the gate's own comparison admits it | |
| **the gate counts less** | not admitted, but within free pages plus cache above the kernel's minimum | The gate's rule refuses, not the Mac's memory; nothing has to close. This is the state the gate's cap produces for a large stage after a download, and it is a finding about the gate |
| **applications must release** | within everything pageable except the kernel's cache minimum | How much applications must release; the kernel's minimum is named as not reclaimable |
| **only a restart** | within everything that is not wired | Even with every application closed it is short, by how much |
| **never** | beyond that, beyond the allocator's limit, or a tensor beyond the GPU's buffer limit | Short by how much |

The memory block is an observation of one moment. It is taken when a session
is planned and says when (`sampledUTC`, printed with the profile); it is not
cached with a speed measurement, whose key has no memory in it. On this pair
the admissible figure of one Mac moved between 27 and 44 GiB within twenty
minutes, and the 173 GB model's cut moved with it.

### How a profile travels

A profile differs per Mac, so it cannot be part of the capability record,
which both Macs must produce byte for byte. It travels beside it, in the
exchange that already carries that record:

- **Locally launched pair** (`start --local --distributed`, the pair driver's
  preflight): the leader already runs `--describe-runtime` on its own worker
  and, over the pinned SSH route, on the peer's. It runs `--describe-device`
  the same way at the same moment. One round trip, a few milliseconds, no GPU.
- **Coordinator-formed pair**: the member adds its profile to the membership
  it already sends in the register message; the coordinator relays both
  profiles with the pair frame, or plans itself with the same pure function.
  Not built; see "Coordinator".
- The chosen plan reaches both ranks the way a plan does today: `--rank`,
  `--stage-cut`, `--generation-mode`, and the plan fingerprint both ranks
  compare in the load agreement before either reads a stage. A rank that was
  told something else stops at the first exchange, as now.

A profile is an observation, not an authority. A peer that overstates its
memory gets a plan its own gate then refuses at load; nothing is admitted on
a profile's word.

## 2. Model layout: what an artifact is made of

`ClusterModelLayout` is derived from the artifact's safetensors headers and
`config.json`. Nothing in it is typed.

- Per layer: stored bytes, loaded bytes, the largest tensor, request state
  (fixed bytes and bytes per context token), a kind label.
- Ingress (what only the first range holds: the embedding) and egress (what
  only the last range holds: final norm and head): bytes and largest tensor.
- Bytes no range loads (vision, MTP, audio), stated so the totals conserve.
- Cut positions in two lists: those the installed runtime admits, and those
  the family's stage plan could make. The planner chooses from the first and
  reports what the second, and every layer boundary, would have given.
- Generation modes, prefill schedules, the request limits, the bytes per
  token of the residual that crosses a cut.
- Identity: runtime model ID, artifact aggregate hash, configuration hash.

### What a family supplies

One protocol, `ClusterPlacementFamily`. Every member is a line or two for a
family that already has a stage plan:

| Member | Meaning |
|---|---|
| `layerCount` | Layers, from the config |
| `admittedCuts` | Stage-0 layer counts the installed runtime admits for this model |
| `structuralCuts` | Stage-0 layer counts at which the family's stage plan can cut (default: the admitted ones) |
| `generationModes` | Modes its runtime executes |
| `maximumPromptTokens`, `maximumOutputTokens`, `maximumChunkTokens` | The largest request |
| `prefillSchedules` | Schedules its runtime executes |
| `boundaryBytesPerToken` | Residual width times its element size |
| `stage(ofStoredTensor:cut:)` | Which of the two stages the family's own plan gives a stored tensor at that cut; nil when no stage loads it |
| `layer(ofStoredTensor:)` | The layer a tensor belongs to; nil for ingress and egress |
| `layerKind(_:)` | A label; layers with one label are assumed to cost the same |
| `requestState(layer:)` | Fixed bytes and bytes per context token of that layer's request state |
| `requestChargeEveryRankBytes` | What the family's request gate charges a rank whatever its range (the Qwen gate charges the whole model's state to either rank); default 0 |
| `loadedBytes(ofStoredTensor:storedBytes:)` | Bytes held once loaded; default the stored size |
| `requestWorkBytes(ofStoredTensor:storedBytes:)` | Bytes that exist a second time while a request runs (weights replaced by a fused copy); default 0 |

The builder asks `stage(ofStoredTensor:cut:)` at every legal cut and requires
the answers to be one step from stage 1 to stage 0 at the tensor's own layer.
A family whose plan is not a contiguous layer pipeline fails there, with the
tensor named. It then requires the bytes to conserve: every stored tensor is
in exactly one layer, the ingress, the egress or the excluded set.

Implemented for the two registered models through `QwenLayerStagePlan`. What
each of the six families in progress must add is at the end.

## 3. Speed estimate

A device's speed on a model is two rates for the whole model on that device
alone, prefill tokens per second at a stated prompt length and decode tokens
per second, each in two states: **rested** (the first request on an idle Mac)
and **sustained** (what repeated requests settle at). A range's time is its
share of the layer cost over that rate. The policy says which state the
ranking optimises. The default is rested until the refinement below exists:
measured on this pair, a Mac's settled rate taken alone understates what it
sustains inside a placement by 15 to 22 %, and a plan made from it moves the
cut too far. Sustained is an option. Both predictions are always printed, the
plan the other state would have chosen is named when it differs, and the
output says which state the placement is the best for.

### The probe, as an interface

`ClusterSpeedMeasurement` is what any family's probe reports, whatever it ran
to get it:

| Field | Unit |
|---|---|
| `rested`, `sustained` | Whole-model tokens per second, prefill and decode, on this device alone. `sustained` is absent when the probe ran once |
| `promptTokens`, `chunkTokens` | The shape the prefill rate was measured at |
| `probedLayers`, `layerCount` | What ran; equal when the whole model ran, otherwise the result was scaled by the layout's layer cost share |
| `loadBytesPerSecond`, `releaseBytesPerSecond` | Verified load (hash included) and release of the probed weights; budgets are derived from these |
| `key` | `artifact aggregate hash + chip + OS build + worker binary hash + probe shape`: two measurements with one key are the same experiment |
| `provenance`, `measuredUTC` | Where the figure came from, in words |

The cheapest honest probe is a **stage probe**: load the smallest admitted
stage 0 through the verified loader, prefill a fixed synthetic prompt in the
profile's chunk size, repeat until the rate settles, run a few decode steps,
release. It measures the real kernels on the real weights on this chip, OS
and binary; it works for a model no single Mac can hold; and its load is the
load figure the budgets need. A whole-model solo run reports through the same
record with `probedLayers == layerCount`. The dense Qwen probe is to be built
from the stage check and the staged reference; until then recorded solo runs
are entered as measurements with their provenance. The MiMo worker's
`--probe-prefill-tokens` can report through the same record.

### Sources, most trusted first

1. **Measured**: this model on this chip, OS build and binary. When several
   exist, the one taken nearest the reference prompt length.
2. **Transferred by a measured ratio** (estimate): this model on another
   device, scaled by the ratio measured for the same two devices on another
   model.
3. **Transferred by the device index** (estimate): the same, scaled by a
   model-free index of each device.
4. **Assumed equal**: nothing is known. The planner still plans, because
   bytes are exact; it says that speed did not inform the split, and prints
   relative figures only.

Every estimate is labelled `ESTIMATE` on the line that shows it and in the
"What this rests on" section; the result's `basis` carries the weakest
source among the devices.

What a measurement cannot see, stated rather than hidden:

- One rate per device per state. Mac B's settled rate depends on how hard the
  placement works it, which two figures cannot express (see the comparison
  with this pair's sweeps).
- It extrapolates from the probed layers to the rest by kind. A family whose
  layers of one kind differ in cost supplies finer kinds.
- A prefill rate depends on prompt length; the shape is in the key and is
  printed.

The device index is an open experiment. Nothing `sysctl` reports says that
the M5 Max prefills the 27B 2.7 times as fast as the M3 Ultra while decoding
it no faster, and GPU core count orders this pair the wrong way round. To be
tried: a one-second model-free benchmark of prefill-shaped and decode-shaped
work, kept only if it orders this pair correctly for both (about 2.7 and
about 1). Until it exists the index is absent and source 4 applies.

## 4. The planner

### Inputs

Devices `d ∈ D` with profiles; a layout with `L` layers and legal boundaries
`B ⊂ {1 … L−1}`; a speed estimate per device; a policy (reference request,
margins, which modes and schedules are allowed).

### A candidate

`R` contiguous ranges, `2 ≤ R ≤ |D|`: boundaries `0 = b₀ < b₁ < … < b_R = L`
with every inner `bᵢ ∈ B`; an injective assignment `π` of ranges to devices;
a mode `m`; a prefill schedule.

### Memory a range needs

With `w_ℓ` the loaded bytes of layer `ℓ`, `h` the largest tensor in the
range, and the gate's own constants from the device's profile (`F` floor,
`G` headroom, `S` scratch):

```
W_r      = Σ_{ℓ ∈ [b_r, b_{r+1})} w_ℓ  + [r = 0]·w_in + [r = R−1]·w_out
           (phase split: the last range holds every layer, W = Σ all)
load_r   = max(F, W_r + inert_r + 2·h_r + S + G)        what the load gate asks first
state_r  = max(charge every rank, Σ state_ℓ(context)) + work_r
request_r = max(F, state_r + G)                           what the request gate asks
need_r   = max(load_r, W_r + request_r)                   admissible before the load
```

`need_r` is compared with `π(r)`'s profile by `admits`, and
`W_r + h_r + allocator headroom` with its allocator limit. Both are the
comparisons the load and request gates make; the planner makes them earlier.

### Time

With `c_ℓ` the layer costs, `C = Σ c_ℓ`, `P_d` and `D_d` device `d`'s whole
model prefill and decode rates, chunk `k`, prompt `T`, outputs `n`:

```
t_r  = (C_r / C) / P_π(r)            prefill seconds per token in range r
u_r  = (C_r / C) / D_π(r)            decode seconds per token in range r

prefill, serial:     T · Σ_r t_r
prefill, lookahead:  T · max_r t_r  +  min(k, T) · (Σ_r t_r − max_r t_r)
first token          = prefill + ⌈T/k⌉ · (R − 1) · x_chunk
decode step, pipeline:     Σ_r u_r + x_step(m)
decode step, phase split:  1 / D_π(R−1)   (after the hand-off; the hand-off delays the second token, not the first)
request              = first token + n · decode step
```

With lookahead the slowest range sets the pace and one chunk passes through
the others. A prompt of one chunk passes through the ranges one after the
other, so it is no sooner than on the faster Mac alone; the gain starts with
the second chunk. The result lists every Mac that, alone, holds the model and
is predicted as fast for the reference request (`aloneAsFast`), and the
output says so.

`x_chunk` and `x_step(m)` are link and protocol costs per chunk and per
decode step. They are properties of the transport and the mode, not of a
model or a Mac, and are measured across the cable. Until they are, they are
zero and the output says the decode figure is an upper bound.

### Decision rule

1. Enumerate every candidate over the admitted cuts (two devices: both
   orders, every cut, every allowed mode; a few hundred evaluations).
2. Give each device in each candidate its answer from section 1. A candidate's
   tier is its worst device's answer. A candidate with a device whose answer
   is "never" is dropped.
3. Rank by, in order: tier; every range inside its device's GPU working set;
   among those that fit now, comfortable before tight (the tightest rank
   keeps at least a tenth of its need in reserve, so memory that moves a
   little between planning and loading does not refuse it); among those that
   do not fit now, the fewest Macs asked for memory, then the least asked, in
   whole GiB; predicted time for the reference request.
4. Equal times are broken by the larger smallest reserve, the lower cut, the
   members' labels in rank order and the mode's place in the layout. Nothing
   depends on the order the devices were given in, so the answer is the same
   whichever Mac asks; a check plans from both sides and compares.

Headroom is a floor, not a goal. An earlier draft treated times within 3 % as
a tie and gave the tie to the roomier candidate; that systematically gave
away up to 3 % of every request for room nobody needed, and was dropped.

The same ranking is run over the cuts the stage plan could make and over
every layer boundary. The result carries all three winners, so what the
runtime's cut list costs and what the stage plan's cut rule costs are each a
number in the output, not an opinion.

The reference request is policy: by default the model profile's largest
request, since that is what the budgets must cover. The command takes
another.

### Refusal rule

The planner refuses only when no candidate survives step 2 and no Mac holds
the model alone: for every order, cut and mode, some device cannot hold its
range whatever is freed. A Mac that holds the whole model is a placement too;
when no division is possible and one Mac can hold it, the result says that
and names the ordinary single-Mac path, and is not a refusal. The refusal states, per device, what it has and the most it could
hold from the start of the model and from its end, whatever is freed; for a
pair, the layers that are left with no Mac able to hold them in the better
order; the admitted placement that comes closest, with each rank's shortfall;
and whether a cut the runtime does not admit, or a layer boundary the stage
plan cannot cut at, would fit. In the last two cases the output says that
the cut list or the cut rule refuses the model, not the Macs' memory.

When candidates exist but none fits now, the result is **not a refusal**. It
is the best candidate with, per device, how much must be freed and of which
kind. The output ends by saying that this is a plan and not an admission: the
load gate on each Mac decides when it loads, on what that Mac has then, and
because the plan and the gate use one rule a rank that fits in the plan is
refused at load only if its memory has changed.

This is the owner's rule made checkable: *a division is chosen ⇔ one is
possible, and the model is refused ⇔ none is and no Mac holds it alone*. A check enumerates every order, cut and mode by plain loops,
evaluates each alone, and requires exactly that, for every constructed device
mix.

### Why cuts sit on the attention interval, and what moving them takes

`QwenLayerStagePlan` admits a cut only at a multiple of
`full_attention_interval`, and the reason is in the SDK, not in the plan. A
stage is the product model built with fewer layers, and `Qwen35DecoderLayer`
decides whether layer `i` is a full-attention or a linear-attention layer from
its index inside that stage: `isLinear = (layerIdx + 1) % fullAttentionInterval != 0`
(`libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`). The two functions
that map a layer to its request state use the same expression. A stage that
started off the interval would build the wrong kind of layer at every
position, load each tensor into a module of the wrong shape, and lay its
state out wrongly. The plan already writes the right `layer_types` into the
stage's configuration; the SDK ignores that key.

Nothing else in the path needs the interval: storage commitments, the load
gate, the residual that crosses the cut and the hand-off are per layer.
Relaxing it takes one SDK change (the layer constructor and the two state
maps honour `layer_types`, or take the stage's first global index), which is
a pin move of `mlx-swift-lm`, then one line in the plan, and the existing
receipts as the oracle since every cut that exists today keeps its bytes. It
is not done here. What it would buy on this pair is in the validation: 2 to
3 % of the first-token time for the 27B.

### Refinement from the running pair (planned, not built)

The first choice comes from each Mac's figures alone, and a Mac's settled
rate is not a property of the Mac alone. On this pair Mac B settles at about
545 tok/s when it serves the 27B by itself (fifteen seconds of prefill per
request) and at about 640 to 675 inside the pair (nine to ten seconds), so a
plan made from the solo sustained figure under-predicts every cut Mac B
limits by 15 to 22 % and picks cut 24 where cut 20 is measured best. The
cuts Mac A limits are predicted within 3 %. No constant is adjusted to hide
this; it is the design's next piece.

- **What is already timed.** Each rank times its own stage per frame: the
  staged reference reports per-frame stage 0, residual copy and stage 1
  times, the worker's qualification record carries the same per rank, and
  the provider's `DistributedRequestObservation` logs first-token time and
  rates per request (logged only; nothing reads it back). The quantity the
  planner needs is each rank's prefill seconds per token in the placement
  that is running: `t_r` measured instead of predicted.
- **The rule.** After a window of requests, compare the ranks' measured
  `t_r`. If the bottleneck is not the rank the plan predicted, or the two
  differ by more than one cut position is worth, move the cut one admitted
  position toward the measured bottleneck (it takes fewer layers) and
  re-plan with the measured rates in place of the solo ones. One position at
  a time, and never to a cut whose memory answer is worse.
- **What a cut change costs.** A cut is fixed for a session: both ranks bind
  the Plan into their load agreement and load their stage against it, so a
  new cut is a new session: both stages reloaded (7 to 14 s per rank for the
  27B, hash included; under a phase split the last rank loads everything)
  and no request in flight. It therefore happens only between requests, at a
  session rotation the envelope already forces (16 requests or 300 s), and
  only when the predicted gain outweighs one reload. Layers moving between
  ranks without a reload would need the stage-transfer work and a second
  agreement; that is not proposed.
- **What it needs.** The per-rank stage time reported in the worker's
  request-finished event (today only in qualification evidence), the
  provider reading its own observations back, and the measured rates stored
  as a `ClusterSpeedMeasurement` whose probe shape names the placement, so
  the estimator can prefer it to a solo figure for that placement.

### Beyond two Macs

The mathematics above is for `R` ranges. For feasibility with a fixed device
order, extending each range as far as its device admits is optimal, because a
range's need only grows with its length; trying every order is `|D|!`. For
the best time, lookahead prefill is a bottleneck partition (minimise
`max_r t_r`) and pipeline decode is an additive one; the planner enumerates
boundary sets exactly while `C(|B|, R−1) · |D|!` is small (three Macs and
MiMo's 47 cuts: 6,486 candidates) and is bounded above that.

What the runtime would need to execute three ranges:

| Piece | Today | Needed |
|---|---|---|
| Stage plan | `QwenLayerStagePlan` requires exactly two ranges | A middle stage: residual in, residual out, embedding and head both inert |
| Storage commitment, conservation | Two ranks hard-coded (`LayerStageStorageConservation`: `rankBytes = [0, 0]`) | `R` ranks |
| Transport | One peer; device matrix 2 × 2 | A chain: each rank reaches its neighbours. A Thunderbolt daisy chain is a line, which is all a pipeline needs; tokens return from the last rank to rank 0 by relay or a third cable |
| Generation driver, agreement, hand-off | Rank 0 and rank 1 by name | A frame relayed through `R−1` hops; lookahead with `R−1` producers; phase split hands every earlier range's state to the last |
| Identity and setup | `ClusterWorkerIdentity.peers` has two entries; `ClusterConfiguration.peers.count == 2` | `R` peers |
| Owner and session | One remote endpoint | `R−1` |
| Capability | A partition is two stages | `R` stages, or the derived form in "Wiring (b)" |

## 5. The command

`darkbloom-cluster-plan`, a product of `libs/darkbloom-cluster-worker`
(macOS 26.2, like the stage check; no JACCL, no model load, no GPU work):

```
darkbloom-cluster-plan device [--json]
darkbloom-cluster-plan layout --model-dir DIR [--json]
darkbloom-cluster-plan plan   (--model-dir DIR | --layout FILE)
                              [--local LABEL] --peer LABEL=PROFILE.json [--peer ...]
                              [--speed MEASUREMENT.json ...] [--index INDEX.json ...] [--link LINK.json]
                              [--prompt-tokens N] [--output-tokens N] [--regime sustained|rested]
                              [--modes MODE,MODE] [--json]
```

`device --json` on one Mac is the `--peer` file on the other. `plan` prints
what each Mac detected, what the model is made of, each Mac's speed with its
source, the chosen placement with each rank's need against what its Mac has,
the predicted first-token time, decode rate and request time for both states,
the reasons, what the choice rests on, the next best placements and each Mac
alone. `--json` prints the same as one object for the provider. Its logic is
`ClusterPlacementTool` in the runtime; the product adds only the sampler.

## What stays policy

Typed on purpose, and listed so that nobody mistakes them for detection:

- The gate's constants (6 GiB floor, 4 GiB headroom, three quarters, the
  32 GiB cap, the compression guard). The planner reads them, it does not own
  them.
- The reference request used to rank, which of the two speed states it
  optimises, the reserve below which a fit counts as tight (a tenth of the
  need) and the share within which a Mac alone is called "as fast" (3 %).
- The margins that turn a predicted time into a budget (wiring (c)).
- The pair-serving grant per model, and which chip pairs are qualified to
  produce equal tokens (decision D4). A plan is not a grant.
- The session envelope (16 requests, 300 s).

## Wiring, in order

**(a) The guided flow.** Built as `darkbloom cluster plan`, a step of the
same command family, reached after the link is ready. The operator states
the pair once (`ClusterPairDescription`: the two members and their
installations, with no leader, no rank and no plan). The step detects this
Mac and reads the model's layout through the plan tool installed beside the
worker, takes the other Mac's profile as that Mac printed it, plans, prints
what it detected and chose in the planner's own words, and writes one setup
per Mac. Rank order follows the plan and the leader is the rank-0 member, so
either Mac can lead whichever one the step is run on, and the ranks meet on
the leader's link address; the output says from which Mac the session is
started. Each Mac approves its own setup with `cluster configure`, as before.
Not done: fetching the peer's profile over the pinned SSH route instead of a
file, and a row for the step in the console (`TUI-wiring.md`). Making the
leader independent of the rank is the topology change X1 of the
prefill-export design and is not part of this.

**(b) Cuts.** The legal cuts become the family's structural rule. The typed
9B list and the 16-partition bound stop limiting the planner. The capability
record keeps its listed partitions, so every existing record, receipt and
agreement keeps its bytes; a cut outside the list is described on request by
the worker for that one cut. The test for this step is the existing receipts
and agreement bytes, unchanged.

**(c) Budgets.** `DistributedInstalledTimeBudgets` is computed from the probe
and the plan: startup from the measured load rate and the bytes each rank
loads; first token from the predicted prefill of the chosen plan; shutdown
from the bytes released; each with its margin stated beside it. The typed
rows remain as the grant and as the fallback when no probe exists.

## Coordinator (not changed here)

An approval pins one `plan_sha256` and an `allowed_chips` list. With a
planner the plan depends on what the two Macs detect on the day, so an
approval of one plan is refused whenever memory moves the cut. What would
have to change, for the private repository to take up:

- Approve an artifact and runtime with a **set** of plans (every legal cut of
  that artifact under that runtime binary), or the planner's policy hash,
  instead of one plan hash. The member reports the plan it chose and why.
- Carry each member's device profile in the membership so that the
  coordinator can check the chosen plan with the same pure function, and
  route only to pairs whose plan fits now.
- `allowed_chips` is a table of known machines. It stays as what it really
  is, the list of chip pairs whose numerics have been qualified against each
  other (D4), and stops doubling as a capacity rule; capacity comes from the
  profiles.

## Validation

- Synthetic device mixes with no table lookups: equal pairs, 16 + 64,
  64 + 512, 128 + 256, tiny + huge, a model larger than the pair, a model
  that fits one way round only, memory mostly in file cache.
- The gate agreement check and the independent enumeration check above.
- This pair: chosen cut and rank order for the 9B and the 27B against the
  measured sweeps, with every disagreement reported and explained. No
  constant is adjusted to close a gap.
- MiMo (173 GB): placed on this pair from detected memory alone; refused on a
  pair that cannot hold it.

## What each family must add

One type in the family's own directory that conforms to
`ClusterPlacementFamily`, and one line in
`ClusterPlacementLayouts.layout(configuration:tensors:)` that picks it for
the family's configuration. Nothing else: the builder, the planner, the
command and the provider step are family-independent. The dense Qwen
conformance (`Models/Placement/QwenDensePlacementFamily.swift`, about ninety
lines with comments) is the model to copy.

Every family answers the same members. What is particular to each:

| Family | `stage(ofStoredTensor:cut:)` and cuts | State per layer | Also |
|---|---|---|---|
| Qwen mixture-of-experts (35B) | Its routed-expert stage plan's parameter mapping; cuts on the attention interval, as for the dense models | As the dense models: keys and values per token on full-attention layers, a fixed convolution and recurrent state on linear ones | `requestWorkBytes` for the projections it fuses; `loadedBytes` if the routed bank's two halves are held differently from how they are stored |
| Gemma 4 | `Gemma4LayerStagePlan`; its 29 cuts as `structuralCuts`, the resident row as `admittedCuts` | Global-attention layers per token; sliding-window layers a fixed window | `loadsAtBothEnds` is true for the tied embedding's three tensors: the first range reads it on the way in and the last holds it as the output projection |
| MiMo V2.6 | Its stage plan; a cut after every layer is structural (1 to 47), the resident row (24 to 34) admitted; `nil` for the vision, audio, speech and MTP tensors | Nine full-attention layers per token, 39 windowed layers fixed | Modes without the phase split, so no rank is asked to hold 156 GiB |
| Bonsai 2 | The dense Qwen plan (same geometry as the 27B); `nil` for the `.signs` tensors, which are verified and not loaded | As the dense 27B, at the dtype its state really has | `boundaryBytesPerToken` from the observed residual dtype (its first hard question), no `requestWorkBytes` (no fusion) |
| GPT-OSS 20B | Its plan slices `layer_types`, so every layer boundary is structural; the resident row admitted | Keys and values only: per token on full layers, a fixed 128-token window on sliding ones | Modes without the phase split until windowed rows can be adopted; `loadedBytes` if the loader fuses gate and up |
| Nemotron 3.5 | Its plan slices `layers_block_type`; every block boundary structural; `nil` for `mtp.` | Mamba blocks fixed, attention blocks per token, MoE blocks none | `layerKind` returns the block kind and `layerCost` its measured relative cost: bytes are 94 % MoE and time may not be, so equal cost per layer would misplace the cut |

Two things the builder checks for every family, so a mistake in a
conformance is an error and not a wrong plan: each tensor's stage steps from 1
to 0 exactly at its own layer across the cuts, and the artifact's stored
bytes are conserved across ingress, layers, egress and the excluded set.

A family's speed probe reports a `ClusterSpeedMeasurement`. Nothing else in
the speed path knows the family.

## What each Mac holds, in one line

`ClusterPlacementExplanation.holdings` says which layers and how many GiB
each Mac holds while a session of a placement is up, beside the Mac's own
size ("mac-b holds layers 0 to 39: 8.65 GiB of weights of its 128.00 GiB;
mac-a holds layers 40 to 63 and, to decode alone, every earlier layer too:
14.12 GiB of weights of its 256.00 GiB"), so a small share on a large Mac is
not read as nothing running. The guided step prints it with the plan.

For the live status view (`darkbloom cluster status`, the console's
`model.ranks` row) the line has two possible sources. The layers are already
there, from the saved setup's Plan. The bytes can come from the layout (one
run of the plan tool's `layout` for the installed model, milliseconds), which
is what the plan said; or from each rank's load receipt, which is what was
loaded. The worker's `ready` event carries request capacity and not loaded
bytes today, so the receipt-backed line needs one field added there. Neither
is wired into the status view yet.

## Status

Built and checked without hardware (`libs/darkbloom-cluster/Tests/PlacementChecks`, 190 checks;
`provider-swift/Tests/ClusterPlacementChecks`, 19 and 7; `libs/darkbloom-cluster-worker/Tests/QualificationChecks`, 42 tests):

- The placement target: profile, layout and builder, estimator, planner,
  budgets, explanation.
- The gate bridge and the check that the profile's reduction of the gate is
  exact.
- The dense Qwen conformance, with layouts that reproduce recorded stage
  sizes and the load gate's recorded asks.
- The plan tool's logic, and the provider's step that turns a placement into
  both members' setups.
- The pair driver's `--local-rank`, so a placement whose first range belongs
  on the second Mac can be run from the Mac that can reach the other.

Built as a product and run on both Macs: `darkbloom-cluster-plan` (`device`
on each Mac; `layout` and `plan` on real artifacts with both Macs' detected
profiles).

Compiled with the installed path's own sources and run end to end with a
stand-in for the plan tool: `ClusterPlacementFlow.run`
(`Tests/ClusterPlacementChecks/run-flow.sh`, 7 checks). Written and not
compiled: the ArgumentParser shell of `darkbloom cluster plan`, which needs
the provider build.

Not built: the speed probe for the dense Qwen models (recorded solo runs
stand in as measurements); the model-free device index has code and has not
been run; wiring (b) and (c) beyond the pure budget derivation; the
refinement above; the status line in the status view.

What was run on the two Macs is in the task's evidence folder
`placement-20261009`.

### Status, later on 2026-10-09 (supersedes the lines above where they differ)

- **The other Mac's profile is fetched, not passed as a file.** `darkbloom
  cluster plan` asks the other Mac's plan tool for that Mac's profile over the
  pinned SSH route the installed session uses
  (`ClusterSSHConfiguration.describeDevice`: the same options, this member's
  identity and pinned known-hosts file, the fixed remote command
  `<worker directory>/darkbloom-cluster-plan device --json`). `--peer-profile`
  remains for a Mac that cannot reach the other. The command's ArgumentParser
  shell is compiled with the provider (native build system), and the step was
  run on the pair it was written on with both Macs' live profiles.
- **What each Mac holds is in the status views.** `ClusterInstalledHoldings`
  reads the layout through the plan tool beside this Mac's worker, computes
  each rank's bytes by the planner's own rule (`ClusterPlacementHoldings`) and
  gives one line to the console (row `model.holdings`) and to `darkbloom
  cluster status` (text output; the JSON report's schema is unchanged). This
  Mac's memory is shown beside its share; the other Mac's is not known to a
  status view. The tool must be this user's own file that nobody else can
  write; it is not pinned by a hash in the setup, and a release should pin
  it. The line from load receipts is not built.
- **The console lists the guided step** as `model.plan`: exists, not wired
  (the screen has no key for it).
- **Not done, and found by the real run:** the installed session is started
  from the leader over SSH, and the leader is rank 0. On a pair where only
  one Mac can open a route to the other (the pair this was written on), a
  placement the other Mac leads cannot be started through the product. Either
  the choice is restricted to placements a given member leads (a policy field
  that filters the orders, with its cost printed like the cut list's), or the
  leader becomes independent of the rank (topology change X1 of the
  prefill-export design).

Mirrored 27B measured (2026-10-09, 18:46Z to 19:11Z, modes step only, cut 48, Mac B rank 0): the second Mac accepts the incoming connection to its rank 0 worker. Phase split: first token 4.20 s at 4,096 and 10.37 s at 8,192 (predicted 4.18 and 8.50), decode 23 to 24 tok/s (predicted 29 to 30). Pipeline in this order: first token 4.08 and 8.64 s, but decode 11.4 tok/s at every length, against 25 to 28 in the normal order; not explained. The first launch (1,024 tokens, phase split) did not become ready within 150 s; the later five did in 16 to 29 s. Token agreement (`record`) and cut 40 not run. The time model needs a per-step term for the relay and for the mirrored pipeline before it can rank orders against each other.

Mirrored 27B, continued after the restart (2026-10-09 23:06Z to 2026-10-10 01:33Z). Tokens: at cut 48, all six recorded runs (pipeline, compact pipeline and phase split at 1,024 and 8,192) pass against both Macs' single-Mac references (tokens equal, or a first difference at a 1-ulp near tie); ranks agree. The 11.4 tok/s was the measuring harness, not the placement: the pair driver ran on the first Mac, rank 0 on the second, and every committed token waits for the driver's decision (rank 0 blocks until it arrives; in the pipeline no next step runs meanwhile, in the phase split rank 0 answers each relayed token the same way). The harness reached the second Mac over a tunnel (median 8 ms, mean 24 ms and p90 128 ms per round trip with decode-like gaps) instead of the cable (0.6 ms). Over the cable, same binaries: pipeline 26.3 tok/s at 1,024 and 25.2 at 8,192, phase split 28.2 and 25.8 (Mac A alone 29.5 and 27.9). Cut 40 over the cable: phase split 28.8 / 27.9 / 27.1 tok/s at 1,024 / 4,096 / 8,192, first token 1.61 / 5.34 / 10.46 s. For the product: the request owner must sit on rank 0's Mac or reach it over the cable; a per-token decision across any slower control route caps decode at one round trip per token. The first-launch timeout did not recur; the second Mac's firewall lists the ad-hoc-signed worker at `bin/phase` as allowed, so a new worker path or new bytes on the Mac that listens is a new firewall decision there (the owner's "approve once" requirement). The time model still needs the relay's per-token cost (about 1.6 to 2.9 ms over the cable at cut 48).
