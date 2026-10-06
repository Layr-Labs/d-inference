package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"

	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// TestPredictServableContextTier covers tier 1 (model context window), which is
// provider-agnostic, so it needs no registered providers.
func TestPredictServableContextTier(t *testing.T) {
	reg := production.New(testLogger())
	model := "ctx-model"

	// prompt 9000 + max 256 = 9256 > contextLimit 8192 → guaranteed-unservable.
	v := reg.PredictServable(model, 9000, 9000, 256, 8192, production.RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("over-context request reported servable: %+v", v)
	}
	if v.Reason != production.ServabilityContextExceeded {
		t.Fatalf("reason = %q, want %q", v.Reason, production.ServabilityContextExceeded)
	}
	if v.RequestTokens != 9256 {
		t.Fatalf("RequestTokens = %d, want 9256 (9000 prompt + 256 max)", v.RequestTokens)
	}
	if v.ContextLimit != 8192 {
		t.Fatalf("ContextLimit = %d, want 8192", v.ContextLimit)
	}

	// prompt 4000 + max 256 = 4256 <= contextLimit 131072 → context tier passes;
	// with an empty fleet the budget tier fails open → servable.
	v = reg.PredictServable(model, 4000, 4000, 256, 131072, production.RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("within-context request reported unservable (must fail open on empty fleet): %+v", v)
	}
	if v.Reason != "" {
		t.Fatalf("reason = %q, want empty for a servable verdict", v.Reason)
	}
	if v.RequestTokens != 4256 {
		t.Fatalf("RequestTokens = %d, want 4256 (4000 prompt + 256 max)", v.RequestTokens)
	}
}

// TestPredictServableTokenBudgetTier covers tier 2 (fleet token-budget ceiling)
// with eligible, resident providers reporting a known active budget. The fleet
// ceiling is the LARGEST budget across providers.
func TestPredictServableTokenBudgetTier(t *testing.T) {
	reg := production.New(testLogger())
	model := "budget-tier-model"
	// Two eligible providers with resident ("running") slots and known budgets;
	// the fleet ceiling is the larger of the two (8192).
	makeTokenBudgetProvider(t, reg, "big", model, 100, 0, 8192, 80)
	makeTokenBudgetProvider(t, reg, "small", model, 100, 0, 4096, 80)

	// prompt 20000 + max 256 = 20256 > fleet max 8192, and every provider's
	// budget is known → confident reject as prompt_too_long. contextLimit=0
	// disables tier 1.
	over := reg.PredictServable(model, 20000, 20000, 256, 0, production.RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("over-budget request reported servable: %+v", over)
	}
	if over.Reason != production.ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, production.ServabilityPromptTooLong)
	}
	if over.RequestTokens != 20256 {
		t.Fatalf("RequestTokens = %d, want 20256", over.RequestTokens)
	}
	if over.FleetMaxBudget != 8192 {
		t.Fatalf("FleetMaxBudget = %d, want 8192 (largest eligible budget)", over.FleetMaxBudget)
	}
	if over.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", over.ProviderCount)
	}

	// prompt 1000 + max 256 = 1256 <= fleet max 8192 → fits → servable.
	within := reg.PredictServable(model, 1000, 1000, 256, 0, production.RequestTraits{}, false)
	if !within.Servable {
		t.Fatalf("within-budget request reported unservable: %+v", within)
	}
	if within.Reason != "" {
		t.Fatalf("reason = %q, want empty for a servable verdict", within.Reason)
	}
	if within.RequestTokens != 1256 {
		t.Fatalf("RequestTokens = %d, want 1256", within.RequestTokens)
	}
	if within.FleetMaxBudget != 8192 {
		t.Fatalf("FleetMaxBudget = %d, want 8192", within.FleetMaxBudget)
	}
}

// TestPredictServableContextPromptOnlyAffectsContextTier guards the DAR-347
// review fix: the calibrated contextPromptTokens must drive ONLY the context
// tier, never the token-budget tier. The budget tier always uses the RAW
// estimate, so a calibration multiplier can never over-reject a request that fits
// a provider's real KV budget (a false-NO / underutilization).
func TestPredictServableContextPromptOnlyAffectsContextTier(t *testing.T) {
	reg := production.New(testLogger())
	model := "context-prompt-isolation-model"
	makeTokenBudgetProvider(t, reg, "p", model, 100, 0, 8192, 80) // fleet max budget 8192

	// Budget tier (contextLimit=0 disables tier 1): raw 4000+256=4256 <= 8192
	// fits. A calibrated context-prompt of 9000 (9256 > 8192) must NOT leak into
	// the budget tier and shed it.
	budget := reg.PredictServable(model, 4000, 9000, 256, 0, production.RequestTraits{}, false)
	if !budget.Servable {
		t.Fatalf("calibrated context prompt leaked into the budget tier and over-rejected a budget-fitting request: %+v", budget)
	}
	if budget.RequestTokens != 4256 {
		t.Fatalf("RequestTokens = %d, want 4256 (budget tier must use the RAW estimate)", budget.RequestTokens)
	}

	// Context tier: raw 4000+256=4256 fits an 8192 context, but the calibrated
	// 9000+256=9256 exceeds it — the context tier DOES use the calibrated prompt.
	ctx := reg.PredictServable(model, 4000, 9000, 256, 8192, production.RequestTraits{}, false)
	if ctx.Servable || ctx.Reason != production.ServabilityContextExceeded {
		t.Fatalf("context tier did not use the calibrated context prompt: %+v", ctx)
	}
	if ctx.RequestTokens != 9256 {
		t.Fatalf("RequestTokens = %d, want 9256 (context tier uses the calibrated prompt)", ctx.RequestTokens)
	}
}

// TestPredictServableFailsOpenOnUnknownBudget proves the fail-open invariant:
// if ANY eligible provider's budget is unknown, the budget tier is skipped even
// for an enormous request — because that provider's true budget might hold it.
func TestPredictServableFailsOpenOnUnknownBudget(t *testing.T) {
	reg := production.New(testLogger())
	model := "fail-open-model"
	// One resident provider with NO reported active budget (legacy → unknown)...
	makeSchedulerProvider(t, reg, "legacy", model, 100)
	// ...alongside one with a small KNOWN budget. The unknown provider must
	// force fail-open regardless of the known ceiling.
	makeTokenBudgetProvider(t, reg, "known-small", model, 100, 0, 4096, 80)

	huge := reg.PredictServable(model, 1_000_000, 1_000_000, 256, 0, production.RequestTraits{}, false)
	if !huge.Servable {
		t.Fatalf("request must fail open when an eligible provider's budget is unknown: %+v", huge)
	}
	if huge.Reason != "" {
		t.Fatalf("reason = %q, want empty (fail open)", huge.Reason)
	}
	if huge.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", huge.ProviderCount)
	}
}

// TestPredictServableKnownZeroColdBudgetUnservable proves the fail-open guard is
// keyed on UNKNOWN budgets, not on a zero ceiling: a fleet whose only eligible
// provider is a cold node with no post-load KV headroom (a KNOWN budget of 0) is
// rejected as prompt_too_long. Otherwise the request would be admitted into a
// guaranteed provider-side token/KV rejection.
func TestPredictServableKnownZeroColdBudgetUnservable(t *testing.T) {
	reg := production.New(testLogger())
	model := "zero-budget-model"
	// 14 GB weights (padded ~15.6 GiB) + the activation reserve exceed 90% of a
	// 16 GB node, so coldTokenBudgetEstimate is 0 (a known zero). MinRAMGB 14 <= 16
	// keeps it past the hardware-fit gate (counted, not model_too_large).
	reg.SetModelCatalog([]production.CatalogEntry{{ID: model, SizeGB: 14, MinRAMGB: 14}})
	makeWarmPoolColdProvider(t, reg, "tight", model, 80, 16, 0)

	v := reg.PredictServable(model, 1000, 1000, 256, 0, production.RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("known-zero-budget fleet reported servable (must reject, not fail open): %+v", v)
	}
	if v.Reason != production.ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", v.Reason, production.ServabilityPromptTooLong)
	}
	if v.ProviderCount != 1 {
		t.Fatalf("ProviderCount = %d, want 1 (cold node fits hardware, counted)", v.ProviderCount)
	}
	if v.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0 (known-zero cold budget)", v.FleetMaxBudget)
	}
}

// TestPredictServableEmptyFleet proves an empty fleet is fail-open: zero
// eligible providers is a different rejection path, never prompt_too_long.
func TestPredictServableEmptyFleet(t *testing.T) {
	reg := production.New(testLogger())

	v := reg.PredictServable("no-such-model", 10_000_000, 10_000_000, 256, 0, production.RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("empty fleet must be servable (fail open): %+v", v)
	}
	if v.Reason != "" {
		t.Fatalf("reason = %q, want empty", v.Reason)
	}
	if v.ProviderCount != 0 {
		t.Fatalf("ProviderCount = %d, want 0", v.ProviderCount)
	}
	if v.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0", v.FleetMaxBudget)
	}
}

// TestColdTokenBudgetEstimate pins the pure cold post-load KV-budget estimator.
// The provider's activation reserve is a FLAT floor — it does not scale with
// context, batch, or attention posture (UnifiedMemoryCap
// .defaultActivationReserveBytes) — so this is one linear expression with no
// regimes and no crossover:
//
//	postLoadGB = servabilityCapFraction*total - size*coldLoadCatalogGBToMemGiB
//	postLoadB  = postLoadGB * bytesPerGB
//	floorB     = floorGB * bytesPerGB   // 5.5*2^30 for a model without a measured floor
//	tokens     = (postLoadB - floorB) / kvBytesPerToken
//
// with servabilityCapFraction=0.90, coldLoadCatalogGBToMemGiB≈
// 1.1175870895385742, bytesPerGB=1<<30, and kvBytesPerToken<=0 → 400000.
// Every case here passes an unmeasured model id (""), so floorGB is the flat
// servabilityActivationFloorGB (5.5, the provider's v0.8.0 B=8 reserve) and
// the weights are the padded catalog figure; the per-model table is pinned by
// TestColdTokenBudgetEstimatePerModelFloor.
//
// A per-token score-tensor surcharge (65536 B/token above a 49152-token
// crossover) briefly made this piecewise. It was removed because the provider
// gate it claimed to mirror never charged it — see
// TestColdTokenBudgetMirrorsProviderReserveArithmetic.
func TestColdTokenBudgetEstimate(t *testing.T) {
	// (a) Roomy node: total=64, size=12, kvpt=400000 — a gpt-oss-shaped cold
	// slot with room for a long context. One regime, so the arithmetic runs
	// straight through:
	//   padded    = 12 * 1.1175870895385742      = 13.41104507446289
	//   postLoadGB= 0.90*64 - 13.41104507446289  = 44.18895492553711 GB
	//   postLoadB = 44.18895492553711 * 2^30     = 47447529062.4 B
	//   tokens    = (47447529062.4 - 5905580032) / 400000 = 103854.87
	// The retired piecewise formula answered 101920 here (at the old 3 GiB
	// floor) — TIGHTER than the provider it claimed to mirror, on a model
	// that materialises no score tensor at all. That gap is the defect.
	const wantRoomy = int64(103854)
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 400000, ""); got != wantRoomy {
		t.Fatalf("roomy estimate = %d, want %d", got, wantRoomy)
	}

	// (b) Tiny node: weights (padded) alone exceed 90% of the 8 GB cap, so
	// there is no post-load memory at all, let alone room for the activation
	// reserve → 0 (never negative).
	if got := memorypolicy.ColdTokenBudgetWithOffload(8, 12, 0, 400000, ""); got != 0 {
		t.Fatalf("tiny-node estimate = %d, want 0 (weights exceed cap)", got)
	}

	// (b1) The OTHER zero, and the one that only exists because the reserve is
	// subtracted separately from the weights: a 20 GB node loading 14 GB of
	// weights clears the cap with 0.90*20 - 14*1.1175870895385742 = 2.3538 GB
	// to spare, so it survives the postLoadGB<=0 early return — but 2.35 GB
	// cannot cover the 5.5 GiB activation floor, so the floor branch computes
	// (2.3538*2^30 - 5905580032)/400000 = -8445.6 and the tokens<=0 guard
	// clamps it. Drop that guard and this returns a NEGATIVE budget, which
	// PredictServable would publish as FleetMaxBudget. Distinct from (b): there
	// the weights alone bust the cap and the reserve never enters it.
	if got := memorypolicy.ColdTokenBudgetWithOffload(20, 14, 0, 400000, ""); got != 0 {
		t.Fatalf("reserve-bound estimate = %d, want 0 (weights fit, activation floor does not)", got)
	}

	// (b2) A 48 GB node loading 28 GB of gemma-4 weights. gemma-4 is the
	// COMPOSED-attention model (head_dim 256 sliding / 512 full, both outside
	// MLX's fused set), and it is charged exactly what fused gpt-oss is: the
	// flat floor, nothing more — because that is all the provider holds back.
	//   padded    = 28 * 1.1175870895385742      = 31.292438507080078
	//   postLoadGB= 0.90*48 - 31.292438507080078 = 11.907561492919925 GB
	//   tokens    = (11.907561492919925*2^30 - 5905580032) / 400000 = 17200.17
	if got := memorypolicy.ColdTokenBudgetWithOffload(48, 28, 0, 400000, ""); got != int64(17200) {
		t.Fatalf("gemma-4-shaped estimate = %d, want 17200", got)
	}

	// (b3) FLAT means LINEAR: equal steps in node memory must buy equal
	// tokens, everywhere. The slope is 0.90*2^30/400000 = 2415.9 tokens per GB,
	// so a 0.05 GB step buys 120.8 — i.e. 120 or 121 after truncation, and
	// nothing else. Re-introduce a piecewise reserve and this fails twice: the
	// slope above the crossover collapses to ~104/step, and the crossover
	// itself plants one anomalous step in the sweep (the retired formula's
	// deltas over this exact range ran 103..121, and it began diverging at
	// total=24.95).
	prev := int64(0)
	for total := 20.0; total <= 30.0; total += 0.05 {
		got := memorypolicy.ColdTokenBudgetWithOffload(total, 1, 0, 400000, "")
		if prev > 0 {
			if d := got - prev; d < 120 || d > 121 {
				t.Fatalf("non-linear step at total=%.2f: %d after %d (delta %d, want 120-121)",
					total, got, prev, d)
			}
		}
		prev = got
	}
	// The sweep must actually cover the region where the retired crossover sat,
	// or the linearity check above never had a chance to catch it.
	if prev <= 49152 {
		t.Fatalf("sweep ended at %d tokens, never reached the retired 49152 crossover region", prev)
	}

	// (c) kvBytesPerToken <= 0 falls back to the kvCacheBytesPerToken default
	// (400000): an unreported per-model KV cost must match the explicit default,
	// for both a zero and a negative input.
	explicit := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 400000, "")
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 0, ""); got != explicit {
		t.Fatalf("kvpt=0 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, -1, ""); got != explicit {
		t.Fatalf("kvpt=-1 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	// A reported per-model KV cost is honored (and a cheaper per-token cost
	// yields strictly more tokens), proving the parameter is actually used.
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 200000, ""); got <= explicit {
		t.Fatalf("cheaper kvpt estimate = %d, want > default-kvpt estimate %d", got, explicit)
	}

	// (d) Unusable inputs → 0 (gate disabled): no total memory, or no model size.
	if got := memorypolicy.ColdTokenBudgetWithOffload(0, 12, 0, 400000, ""); got != 0 {
		t.Fatalf("totalMemoryGB<=0 estimate = %d, want 0", got)
	}
	if got := memorypolicy.ColdTokenBudgetWithOffload(-1, 12, 0, 400000, ""); got != 0 {
		t.Fatalf("totalMemoryGB<0 estimate = %d, want 0", got)
	}
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 0, 0, 400000, ""); got != 0 {
		t.Fatalf("modelSizeGB<=0 estimate = %d, want 0", got)
	}
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, -1, 0, 400000, ""); got != 0 {
		t.Fatalf("modelSizeGB<0 estimate = %d, want 0", got)
	}
}

// TestSnapshotStructuralBudget pins how a single provider's snapshot maps to a
// structural token budget and whether that budget is known (fail-open) per the
// three branches in snapshotStructuralBudget.
func TestSnapshotStructuralBudget(t *testing.T) {
	// Resident slot with a reported active budget: authoritative and known.
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{ActiveTokenBudgetMax: 8192})); !known || budget != 8192 {
		t.Fatalf("resident-with-budget = (%d, %v), want (8192, true)", budget, known)
	}

	// The reported active budget wins even when memory/size data is also present
	// (it must NOT fall through to the cold estimate for a loaded model).
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{
		ActiveTokenBudgetMax: 8192,
		ModelLoaded:          true,
		TotalMemoryGB:        64,
		ModelSizeGB:          12,
	})); !known || budget != 8192 {
		t.Fatalf("resident-with-budget+mem = (%d, %v), want (8192, true)", budget, known)
	}

	// Resident but no budget reported (legacy provider): unknown → fail-open.
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{ModelLoaded: true})); known || budget != 0 {
		t.Fatalf("resident-no-budget = (%d, %v), want (0, false)", budget, known)
	}

	// Cold/on-disk with memory + size data: known, using the optimistic cold
	// estimate. Unreported kvBytesPerToken falls back to the 400000 default.
	wantCold := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 0, "")
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{TotalMemoryGB: 64, ModelSizeGB: 12})); !known || budget != wantCold {
		t.Fatalf("cold-fitting = (%d, %v), want (%d, true)", budget, known, wantCold)
	}
	// A cold slot threads its reported per-model KV cost into the estimate.
	wantColdKVPT := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 200000, "")
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{
		TotalMemoryGB:   64,
		ModelSizeGB:     12,
		KVBytesPerToken: 200000,
	})); !known || budget != wantColdKVPT {
		t.Fatalf("cold-fitting+kvpt = (%d, %v), want (%d, true)", budget, known, wantColdKVPT)
	}
	// A cold slot threads the routed model into the estimate: gpt-oss-20b
	// is charged its measured residency and measured activation floor, which
	// lands strictly above the unmeasured-model default above.
	wantColdMeasured := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 0, "gpt-oss-20b")
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{
		Model:         "gpt-oss-20b",
		TotalMemoryGB: 64,
		ModelSizeGB:   12,
	})); !known || budget != wantColdMeasured {
		t.Fatalf("cold-fitting+model = (%d, %v), want (%d, true)", budget, known, wantColdMeasured)
	}
	if wantColdMeasured <= wantCold {
		t.Fatalf("measured gpt-oss cold budget %d must sit above the unmeasured cold budget %d (smaller floor and weights)",
			wantColdMeasured, wantCold)
	}

	// Cold but missing memory or size data: cannot estimate → unknown.
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{ModelSizeGB: 12})); known || budget != 0 {
		t.Fatalf("cold-missing-memory = (%d, %v), want (0, false)", budget, known)
	}
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{TotalMemoryGB: 64})); known || budget != 0 {
		t.Fatalf("cold-missing-size = (%d, %v), want (0, false)", budget, known)
	}

	// Cold with memory + size data but NO post-load KV headroom (weights ~fill the
	// node): the estimate is 0 yet it is a KNOWN budget, not "unknown" — so the
	// gate can confidently reject rather than fail open.
	if budget, known := memorypolicy.StructuralBudget(memoryInputPtr(memorypolicy.Input{TotalMemoryGB: 16, ModelSizeGB: 14})); !known || budget != 0 {
		t.Fatalf("cold-no-headroom = (%d, %v), want (0, true)", budget, known)
	}
}

// TestServabilityActivationFloorPerModel pins the per-model floor selection,
// mirroring what the provider holds (UnifiedMemoryCap.resolvedActivationReserveBytes):
// the measured per-model floor for models in the mirrored table (gpt-oss-20b:
// 3.5 = worst measured B=8 peak, 3.20 GiB compiled, + slack), the flat 5.5
// otherwise. The table mirrors UnifiedMemoryCap.measuredActivationFloorsBytes
// and the two MUST move in the same commit.
//
// The per-model figure is a LOWER bound on the reserve a multi-model provider
// holds (its UnifiedMemoryCap takes the max over its whole serving set, which
// the coordinator does not know) — the optimistic direction this file
// sanctions: worst case is a declined load the dispatch path retries, and the
// warm report replaces the estimate as soon as the slot loads.
func TestServabilityActivationFloorPerModel(t *testing.T) {
	cases := []struct {
		model string
		want  float64
	}{
		{"gpt-oss-20b", 3.5},                  // measured floor
		{"qwen3.6-35b-a3b-vl-mtp-mxfp8", 5.5}, // vision-capable → default until vision-inclusive measurement
		{"qwen3.5-35b-a3b", 5.5},              // vision-capable → default
		{"gemma-4-26b", 5.5},                  // unmeasured → flat
		{"", 5.5},                             // unknown model → flat
	}
	for _, tc := range cases {
		if got := memorypolicy.ActivationFloor(tc.model); got != tc.want {
			t.Fatalf("servabilityActivationFloor(%q) = %v, want %v", tc.model, got, tc.want)
		}
	}
}

// TestColdTokenBudgetEstimatePerModelFloor pins the cold estimate under the
// per-model floor. Same roomy node as TestColdTokenBudgetEstimate (total=64,
// size=12, kvpt=400000, postLoadB = 47447529062.4):
//
//	gpt-oss-20b (MEASURED weights 11.5 GiB + measured floor 3.5):
//	  (0.9*64 - 11.5)*2^30 = 46.1*2^30 = 49499498086.4
//	  (49499498086.4 - 3758096384)/400000 = 114353.50
//	unmeasured-in-both-tables (padded weights + flat floor):
//	  (47447529062.4 - 5.5*2^30)/400000 = 103854.87
func TestColdTokenBudgetEstimatePerModelFloor(t *testing.T) {
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 400000, "gpt-oss-20b"); got != int64(114353) {
		t.Fatalf("per-model gpt-oss estimate = %d, want 114353 (measured weights + floor)", got)
	}
	// gemma-4-26b-qat-4bit sits in NEITHER table (vision-capable → no measured
	// residency; no measured activation floor): padded weights + flat floor.
	if got := memorypolicy.ColdTokenBudgetWithOffload(64, 12, 0, 400000, "gemma-4-26b-qat-4bit"); got != int64(103854) {
		t.Fatalf("per-model dual-unmeasured estimate = %d, want 103854 (padded + flat floor)", got)
	}
}

// TestColdTokenBudgetMirrorsProviderReserveArithmetic is the regression for the
// coordinator/provider activation-reserve desync.
//
// coldTokenBudgetEstimate exists to reproduce ONE thing: the post-load KV budget
// UnifiedMemoryCap will actually leave a freshly-loaded slot. That budget is
// cap − paddedWeights − a FLAT 5.5 GiB reserve, and once the slot is resident the
// provider reports precisely it back as active_token_budget_max
// (EngineV2Bridge+Capacity: kvBytesCapacity / kvBytesPerToken), which
// snapshotStructuralBudget then prefers. The cold estimate must therefore
// converge to the warm report — for EVERY model, including one whose attention
// composes.
//
// The shipped defect: the coordinator charged every cold model a 65536 B/token
// score-tensor surcharge that no provider gate ever held back
// (UnifiedMemoryCap.ActivationReserveShape had zero call sites, so every gate
// took the flat floor). That made this predictor strictly TIGHTER than the gate
// it mirrors and 429'd prompts the fleet could serve. gpt-oss-20b — head_dim 64,
// inside MLX's fused-SDPA set {64, 80, 128}, so it materialises no score tensor
// whatsoever — was surcharged anyway.
//
// Both fleet models are pinned, against the provider formula recomputed
// independently below rather than against a copied literal, so a surcharge
// re-added for EITHER attention posture breaks this.
func TestColdTokenBudgetMirrorsProviderReserveArithmetic(t *testing.T) {
	for _, tc := range []struct {
		model         string
		posture       string
		totalMemoryGB float64
		modelSizeGB   float64
	}{
		// head_dim 64 → FUSED. No prefill score tensor exists for this model,
		// and it was the loudest victim of the surcharge.
		{"gpt-oss-20b", "fused, head_dim 64", 64, 12},
		// head_dim 256 (sliding) / 512 (full) → COMPOSED. This one really does
		// materialise the larger score tensor, and the provider STILL holds
		// back only the flat floor for it, so the coordinator must too.
		{"gemma-4-26b", "composed, head_dim 256/512", 128, 28},
	} {
		got := memorypolicy.ColdTokenBudgetWithOffload(tc.totalMemoryGB, tc.modelSizeGB, 0, 400000, "")
		want := providerPostLoadTokenBudget(tc.totalMemoryGB, tc.modelSizeGB, 400000, 5.5)
		if got != want {
			t.Errorf("%s (%s): cold estimate = %d, want the provider's own post-load budget %d",
				tc.model, tc.posture, got, want)
		}
		// Premise: both shapes sit ABOVE the retired 49152-token crossover, so
		// a re-added surcharge would move them. Without this the case could
		// pass vacuously on inputs where the flat floor bound either way.
		if got <= 49152 {
			t.Errorf("%s: budget %d is below the retired crossover — case no longer discriminates",
				tc.model, got)
		}
	}

	// Direction matters more than any single point: across the fleet's real box
	// sizes and weight footprints the coordinator must never land BELOW the
	// provider. Coming in tighter is what turns into a terminal 429 on a prompt
	// the provider would have served; coming in looser only costs a declined
	// load, which dispatch retries elsewhere. An unmeasured model is mirrored
	// against the flat 5.5 GiB gate the provider holds for it.
	for _, totalGB := range []float64{24, 36, 48, 64, 96, 128, 192, 512} {
		for _, sizeGB := range []float64{1, 12, 20, 28, 40} {
			got := memorypolicy.ColdTokenBudgetWithOffload(totalGB, sizeGB, 0, 400000, "")
			want := providerPostLoadTokenBudget(totalGB, sizeGB, 400000, 5.5)
			if got < want {
				t.Fatalf("total=%.0fGB size=%.0fGB: cold estimate %d is TIGHTER than the provider's %d",
					totalGB, sizeGB, got, want)
			}
		}
	}
}

// providerPostLoadTokenBudget recomputes the PROVIDER's post-load KV token
// budget from the provider's own constants, in bytes throughout — deliberately
// not sharing coldTokenBudgetEstimate's GB-then-bytes ordering:
//
//	UnifiedMemoryCap.kvBudgetBytes = 0.90*physical − paddedWeights − reserve
//	active_token_budget_max        = kvBudgetBytes / kvBytesPerToken
//
// reserveGB is spelled as a literal at each CALL SITE (5.5 —
// UnifiedMemoryCap.defaultActivationReserveBytes) rather than read from the
// servability constants, on purpose: if one side's reserve is retuned and the
// other is not, those literals are what fail — as they did (by design) when
// the provider moved 3 → 5.5 for v0.8.0's B=8 activation peak, forcing this
// file to move with it. (BytesPerGB and ColdLoadCatalogGBToMemGiB are shared
// because they are unit conversions, not policy.)
func providerPostLoadTokenBudget(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64, reserveGB float64) int64 {
	reserveBytes := reserveGB * float64(admission.BytesPerGB)
	capBytes := 0.90 * totalMemoryGB * float64(admission.BytesPerGB)
	weightBytes := modelSizeGB * admission.ColdLoadCatalogGBToMemGiB * float64(admission.BytesPerGB)
	free := capBytes - weightBytes - reserveBytes
	if free <= 0 {
		return 0
	}
	return int64(free / float64(kvBytesPerToken))
}

// TestServabilityColdWeightsPerModel pins the per-model weights term: measured
// resident GiB for measured text-only models, the catalog-padded conversion
// otherwise. Vision-capable models are deliberately absent from the measured
// table (text-only bench residency under-counts their towers) and must keep
// the padded figure.
func TestServabilityColdWeightsPerModel(t *testing.T) {
	padded := func(sz float64) float64 { return sz * admission.ColdLoadCatalogGBToMemGiB }
	cases := []struct {
		model         string
		catalogSizeGB float64
		want          float64
	}{
		{"gemma-4-26b-8bit", 28.0, padded(28.0)},             // VLM artifact → padded pending provider-path measurement
		{"gemma-4-26b", 28.0, padded(28.0)},                  // VLM artifact → padded
		{"gpt-oss-20b", 12.1, 11.5},                          // measured residency (text-only artifact)
		{"qwen3.6-35b-a3b-vl-mtp-mxfp8", 21.3, padded(21.3)}, // vision-capable → padded
		{"unknown-model", 10.0, padded(10.0)},                // unmeasured → padded
	}
	for _, tc := range cases {
		if got := memorypolicy.ColdWeightsGiB(tc.model, tc.catalogSizeGB); got != tc.want {
			t.Fatalf("servabilityColdWeightsGiB(%q, %v) = %v, want %v",
				tc.model, tc.catalogSizeGB, got, tc.want)
		}
	}

	// gemma-8bit stays padded (VLM artifact) for now — the 36 GB tier unblock
	// is gated on a provider-path residency measurement:
	if got := memorypolicy.ColdTokenBudgetWithOffload(36, 28, 0, 400000, "gemma-4-26b-8bit"); got != 0 {
		t.Fatalf("gemma-8bit@36 estimate = %d, want 0 (still padded pending VLM-path measurement)", got)
	}
	// The measured text-only model DOES take the measured figure in the
	// POST-load estimate: gpt-oss on a 24 GB box gains the difference over an
	// unmeasured model of the same catalog size (padded 13.53 vs measured 11.5,
	// flat 5.5 vs measured 3.5 floor).
	if got, want := memorypolicy.ColdTokenBudgetWithOffload(24, 12.1, 0, 400000, "gpt-oss-20b"),
		memorypolicy.ColdTokenBudgetWithOffload(24, 12.1, 0, 400000, "unknown-model"); got <= want {
		t.Fatalf("gpt-oss@24 estimate = %d, want > unmeasured %d (measured weights + floor)", got, want)
	}
	// The ADMIT gate, by contrast, charges the PADDED figure for EVERY
	// model — the load transient exceeds steady residency, so a
	// measured-weights admit would over-admit loads that OOM mid-staging.
	free := 12.0 // fits measured 11.5, NOT padded 13.53
	if admit, reported := admission.ReportedLoadAdmits(12.1, 0, free, true); !reported || admit {
		t.Fatalf("admit gate = (%v, %v), want (false, true): padded transient figure must govern admits", admit, reported)
	}
	roomy := 14.0 // fits padded 13.53
	if admit, reported := admission.ReportedLoadAdmits(12.1, 0, roomy, true); !reported || !admit {
		t.Fatalf("admit gate = (%v, %v), want (true, true)", admit, reported)
	}
}
