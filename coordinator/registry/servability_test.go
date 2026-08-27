package registry

import "testing"

// TestColdTokenBudgetEstimate pins the pure cold post-load KV-budget estimator.
// Current providers report the exact reserve selected by Swift's measured
// execution-profile policy. Older providers omit it, so the coordinator uses a
// flat compatibility fallback selected by binary version:
//
//	postLoadGB = servabilityCapFraction*total - size*coldLoadCatalogGBToMemGiB
//	postLoadB  = postLoadGB * bytesPerGB
//	reserveB   = reported bytes, else 5.5*2^30 (≥0.8.0) or 3*2^30 (legacy)
//	tokens     = (postLoadB - reserveB) / kvBytesPerToken
//
// with servabilityCapFraction=0.90, coldLoadCatalogGBToMemGiB≈
// 1.1175870895385742, bytesPerGB=1<<30, and kvBytesPerToken<=0 → 400000.
// The fallback moved 3.0 → 5.5 GiB with v0.8.0. An empty/pre-0.8.0 version keeps
// 3 GiB because that is what those binaries hold. A reported value always wins:
// this is how the coordinator mirrors model-aware Swift policy without
// reimplementing the model classifier.
//
// A per-token score-tensor surcharge (65536 B/token above a 49152-token
// crossover) briefly made this piecewise. It was removed because the provider
// gate it claimed to mirror never charged it — see
// TestColdTokenBudgetMirrorsProviderReserveArithmetic.
func TestColdTokenBudgetEstimate(t *testing.T) {
	const v080 = "0.8.0"
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
	if got := coldTokenBudgetEstimate(64, 12, 400000, v080, 0); got != wantRoomy {
		t.Fatalf("roomy estimate = %d, want %d", got, wantRoomy)
	}
	if got := coldTokenBudgetEstimate(64, 12, 400000, v080, 0); got <= 0 {
		t.Fatalf("roomy estimate = %d, want > 0", got)
	}

	// (a1) The same box under a LEGACY binary: a pre-0.8.0 provider still
	// holds the old 3 GiB reserve, so its estimate is exactly 2.5*2^30/400000
	// = 6710.9 tokens higher — (47447529062.4 - 3221225472)/400000 = 110565.7.
	// An EMPTY (unreported) version fails toward the same legacy budget: the
	// larger estimate is the fail-open direction (see
	// servabilityActivationReserveBytes).
	const wantRoomyLegacy = int64(110565)
	if got := coldTokenBudgetEstimate(64, 12, 400000, "0.7.12", 0); got != wantRoomyLegacy {
		t.Fatalf("legacy roomy estimate = %d, want %d", got, wantRoomyLegacy)
	}
	if got := coldTokenBudgetEstimate(64, 12, 400000, "", 0); got != wantRoomyLegacy {
		t.Fatalf("unreported-version roomy estimate = %d, want %d (fail toward legacy)", got, wantRoomyLegacy)
	}
	// The gate is >= 0.8.0, not > 0.8.0, and later releases keep the floor.
	if got := coldTokenBudgetEstimate(64, 12, 400000, "0.8.1", 0); got != wantRoomy {
		t.Fatalf("post-0.8.0 estimate = %d, want %d", got, wantRoomy)
	}
	// Current providers report the resolved model profile. GPT-OSS 20B's
	// measured 3 GiB value overrides the 5.5 GiB v0.8 fallback exactly.
	if got := coldTokenBudgetEstimate(
		64, 12, 400000, v080, 3*bytesPerGB,
	); got != wantRoomyLegacy {
		t.Fatalf("reported 3 GiB profile estimate = %d, want %d", got, wantRoomyLegacy)
	}
	// Reported bytes are authoritative regardless of the version fallback.
	const sevenGiB = uint64(7 * bytesPerGB)
	wantSevenGiB := providerPostLoadTokenBudget(64, 12, 400000, 7)
	if got := coldTokenBudgetEstimate(
		64, 12, 400000, "0.7.12", sevenGiB,
	); got != wantSevenGiB {
		t.Fatalf("reported 7 GiB profile estimate = %d, want %d", got, wantSevenGiB)
	}

	// (b) Tiny node: weights (padded) alone exceed 90% of the 8 GB cap, so
	// there is no post-load memory at all, let alone room for the activation
	// reserve → 0 (never negative).
	if got := coldTokenBudgetEstimate(8, 12, 400000, v080, 0); got != 0 {
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
	if got := coldTokenBudgetEstimate(20, 14, 400000, v080, 0); got != 0 {
		t.Fatalf("reserve-bound estimate = %d, want 0 (weights fit, activation floor does not)", got)
	}

	// (b2) A 48 GB node loading 28 GB of gemma-4 weights. With no reported
	// profile, a v0.8 provider uses the conservative 5.5 GiB fallback.
	//   padded    = 28 * 1.1175870895385742      = 31.292438507080078
	//   postLoadGB= 0.90*48 - 31.292438507080078 = 11.907561492919925 GB
	//   tokens    = (11.907561492919925*2^30 - 5905580032) / 400000 = 17200.17
	if got := coldTokenBudgetEstimate(48, 28, 400000, v080, 0); got != int64(17200) {
		t.Fatalf("gemma-4-shaped estimate = %d, want 17200", got)
	}
	// The same box under a legacy binary: 3 GiB floor →
	// (11.907561492919925*2^30 - 3221225472)/400000 = 23911.1.
	if got := coldTokenBudgetEstimate(48, 28, 400000, "0.7.12", 0); got != int64(23911) {
		t.Fatalf("legacy gemma-4-shaped estimate = %d, want 23911", got)
	}

	// (b3) For any one reported/fallback profile the reserve is a constant byte
	// count, so equal steps in node memory buy equal tokens. The slope is
	// 0.90*2^30/400000 = 2415.9 tokens per GB; a 0.05 GB step buys 120 or 121
	// after truncation. Re-introducing a coordinator-only per-token surcharge
	// makes this piecewise and breaks the mirror.
	prev := int64(0)
	for total := 20.0; total <= 30.0; total += 0.05 {
		got := coldTokenBudgetEstimate(total, 1, 400000, v080, 0)
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
	explicit := coldTokenBudgetEstimate(64, 12, 400000, v080, 0)
	if got := coldTokenBudgetEstimate(64, 12, 0, v080, 0); got != explicit {
		t.Fatalf("kvpt=0 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	if got := coldTokenBudgetEstimate(64, 12, -1, v080, 0); got != explicit {
		t.Fatalf("kvpt=-1 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	// A reported per-model KV cost is honored (and a cheaper per-token cost
	// yields strictly more tokens), proving the parameter is actually used.
	if got := coldTokenBudgetEstimate(64, 12, 200000, v080, 0); got <= explicit {
		t.Fatalf("cheaper kvpt estimate = %d, want > default-kvpt estimate %d", got, explicit)
	}

	// (d) Unusable inputs → 0 (gate disabled): no total memory, or no model size.
	if got := coldTokenBudgetEstimate(0, 12, 400000, v080, 0); got != 0 {
		t.Fatalf("totalMemoryGB<=0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(-1, 12, 400000, v080, 0); got != 0 {
		t.Fatalf("totalMemoryGB<0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(64, 0, 400000, v080, 0); got != 0 {
		t.Fatalf("modelSizeGB<=0 estimate = %d, want 0", got)
	}
	if got := coldTokenBudgetEstimate(64, -1, 400000, v080, 0); got != 0 {
		t.Fatalf("modelSizeGB<0 estimate = %d, want 0", got)
	}
}

// TestColdTokenBudgetMirrorsProviderReserveArithmetic is the regression for the
// coordinator/provider activation-reserve desync.
//
// coldTokenBudgetEstimate exists to reproduce ONE thing: the post-load KV budget
// UnifiedMemoryCap will actually leave a freshly-loaded slot:
// cap − paddedWeights − the provider-reported model reserve. Once resident, the
// provider reports the resulting active_token_budget_max, which
// snapshotStructuralBudget prefers. The cold estimate must converge to that warm
// report for every profile.
//
// The shipped defect: the coordinator charged every cold model a 65536 B/token
// score-tensor surcharge that no provider gate ever held back
// (UnifiedMemoryCap.ActivationReserveShape had zero call sites, so every gate
// took its configured fallback). That made this predictor strictly TIGHTER than the gate
// it mirrors and 429'd prompts the fleet could serve. gpt-oss-20b — head_dim 64,
// inside MLX's fused-SDPA set {64, 80, 128}, so it materialises no score tensor
// whatsoever — was surcharged anyway.
//
// Both measured fleet profiles are pinned against the provider formula
// recomputed independently below. Swift selects the reserve and reports its
// resolved bytes; Go must consume those bytes without deriving its own profile.
func TestColdTokenBudgetMirrorsProviderReserveArithmetic(t *testing.T) {
	for _, tc := range []struct {
		model                string
		posture              string
		totalMemoryGB        float64
		modelSizeGB          float64
		reportedReserveBytes uint64
		providerReserveGiB   float64
	}{
		{
			model: "gpt-oss-20b", posture: "fused, head_dim 64",
			totalMemoryGB: 64, modelSizeGB: 12,
			reportedReserveBytes: 3 * bytesPerGB, providerReserveGiB: 3,
		},
		{
			model: "gemma-4-26b", posture: "composed, head_dim 256/512",
			totalMemoryGB: 128, modelSizeGB: 28,
			reportedReserveBytes: 11 * bytesPerGB / 2, providerReserveGiB: 5.5,
		},
	} {
		got := coldTokenBudgetEstimate(
			tc.totalMemoryGB,
			tc.modelSizeGB,
			400000,
			"0.8.0",
			tc.reportedReserveBytes,
		)
		want := providerPostLoadTokenBudget(
			tc.totalMemoryGB, tc.modelSizeGB, 400000, tc.providerReserveGiB)
		if got != want {
			t.Errorf("%s (%s): cold estimate = %d, want the provider's own post-load budget %d",
				tc.model, tc.posture, got, want)
		}
		// Premise: both shapes sit ABOVE the retired 49152-token crossover, so
		// a re-added surcharge would move them. Without this the case could
		// pass vacuously on inputs where the reserve bound either way.
		if got <= 49152 {
			t.Errorf("%s: budget %d is below the retired crossover — case no longer discriminates",
				tc.model, got)
		}
	}

	// Across real box sizes and weight footprints, each reported profile must
	// equal the provider byte-for-byte. Coming in tighter creates terminal 429s;
	// coming in looser dispatches work the provider will reject.
	for _, totalGB := range []float64{24, 36, 48, 64, 96, 128, 192, 512} {
		for _, sizeGB := range []float64{1, 12, 20, 28, 40} {
			for _, reserveGiB := range []float64{3, 5.5, 7} {
				reported := uint64(reserveGiB * float64(bytesPerGB))
				got := coldTokenBudgetEstimate(
					totalGB, sizeGB, 400000, "0.8.0", reported)
				want := providerPostLoadTokenBudget(
					totalGB, sizeGB, 400000, reserveGiB)
				if got != want {
					t.Fatalf("total=%.0fGB size=%.0fGB reserve=%.1fGiB: cold estimate %d, provider %d",
						totalGB, sizeGB, reserveGiB, got, want)
				}
			}

			// Unreported values retain per-binary compatibility.
			currentGot := coldTokenBudgetEstimate(
				totalGB, sizeGB, 400000, "0.8.0", 0)
			currentWant := providerPostLoadTokenBudget(
				totalGB, sizeGB, 400000, 5.5)
			if currentGot != currentWant {
				t.Fatalf("total=%.0fGB size=%.0fGB: current fallback %d, provider %d",
					totalGB, sizeGB, currentGot, currentWant)
			}
			legacyGot := coldTokenBudgetEstimate(totalGB, sizeGB, 400000, "0.7.12", 0)
			legacyWant := providerPostLoadTokenBudget(totalGB, sizeGB, 400000, 3.0)
			if legacyGot != legacyWant {
				t.Fatalf("total=%.0fGB size=%.0fGB: legacy fallback %d, provider %d",
					totalGB, sizeGB, legacyGot, legacyWant)
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
// reserveGB is supplied independently at each call site instead of reading a
// servability constant. If provider and coordinator policy drift, these
// literals fail. bytesPerGB and coldLoadCatalogGBToMemGiB are shared because
// they are unit conversions, not activation policy.
func providerPostLoadTokenBudget(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64, reserveGB float64) int64 {
	reserveBytes := reserveGB * float64(bytesPerGB)
	capBytes := 0.90 * totalMemoryGB * float64(bytesPerGB)
	weightBytes := modelSizeGB * coldLoadCatalogGBToMemGiB * float64(bytesPerGB)
	free := capBytes - weightBytes - reserveBytes
	if free <= 0 {
		return 0
	}
	return int64(free / float64(kvBytesPerToken))
}

// TestSnapshotStructuralBudget pins how a single provider's snapshot maps to a
// structural token budget and whether that budget is known (fail-open) per the
// three branches in snapshotStructuralBudget.
func TestSnapshotStructuralBudget(t *testing.T) {
	// Resident slot with a reported active budget: authoritative and known.
	if budget, known := snapshotStructuralBudget(routingSnapshot{activeTokenBudgetMax: 8192}); !known || budget != 8192 {
		t.Fatalf("resident-with-budget = (%d, %v), want (8192, true)", budget, known)
	}

	// The reported active budget wins even when memory/size data is also present
	// (it must NOT fall through to the cold estimate for a loaded model).
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		activeTokenBudgetMax: 8192,
		modelLoaded:          true,
		totalMemoryGB:        64,
		modelSizeGB:          12,
	}); !known || budget != 8192 {
		t.Fatalf("resident-with-budget+mem = (%d, %v), want (8192, true)", budget, known)
	}

	// Resident but no budget reported (legacy provider): unknown → fail-open.
	if budget, known := snapshotStructuralBudget(routingSnapshot{modelLoaded: true}); known || budget != 0 {
		t.Fatalf("resident-no-budget = (%d, %v), want (0, false)", budget, known)
	}

	// Cold/on-disk with memory + size data: known, using the optimistic cold
	// estimate. Unreported kvBytesPerToken falls back to the 400000 default;
	// an unreported binaryVersion falls toward the legacy reserve.
	wantCold := coldTokenBudgetEstimate(64, 12, 0, "", 0)
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 64, modelSizeGB: 12}); !known || budget != wantCold {
		t.Fatalf("cold-fitting = (%d, %v), want (%d, true)", budget, known, wantCold)
	}
	// A cold slot threads its reported per-model KV cost into the estimate.
	wantColdKVPT := coldTokenBudgetEstimate(64, 12, 200000, "", 0)
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		totalMemoryGB:   64,
		modelSizeGB:     12,
		kvBytesPerToken: 200000,
	}); !known || budget != wantColdKVPT {
		t.Fatalf("cold-fitting+kvpt = (%d, %v), want (%d, true)", budget, known, wantColdKVPT)
	}
	// A cold slot threads its provider's binary version into the estimate:
	// a ≥0.8.0 binary is charged the 5.5 GiB reserve it actually holds,
	// which lands strictly below the legacy default above.
	wantColdV080 := coldTokenBudgetEstimate(64, 12, 0, "0.8.0", 0)
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		totalMemoryGB: 64,
		modelSizeGB:   12,
		binaryVersion: "0.8.0",
	}); !known || budget != wantColdV080 {
		t.Fatalf("cold-fitting+version = (%d, %v), want (%d, true)", budget, known, wantColdV080)
	}
	if wantColdV080 >= wantCold {
		t.Fatalf("v0.8.0 cold budget %d must sit below the legacy cold budget %d (bigger reserve)",
			wantColdV080, wantCold)
	}
	// A current model's reported profile overrides the binary fallback and is
	// threaded through the snapshot. GPT-OSS 20B reports the measured 3 GiB
	// reserve, restoring exactly the corresponding post-load KV budget.
	wantReported := coldTokenBudgetEstimate(64, 12, 0, "0.8.0", 3*bytesPerGB)
	if budget, known := snapshotStructuralBudget(routingSnapshot{
		totalMemoryGB:          64,
		modelSizeGB:            12,
		binaryVersion:          "0.8.0",
		activationReserveBytes: 3 * bytesPerGB,
	}); !known || budget != wantReported {
		t.Fatalf("cold-fitting+reported-reserve = (%d, %v), want (%d, true)",
			budget, known, wantReported)
	}
	if wantReported <= wantColdV080 {
		t.Fatalf("3 GiB reported budget %d must exceed 5.5 GiB fallback budget %d",
			wantReported, wantColdV080)
	}

	// Cold but missing memory or size data: cannot estimate → unknown.
	if budget, known := snapshotStructuralBudget(routingSnapshot{modelSizeGB: 12}); known || budget != 0 {
		t.Fatalf("cold-missing-memory = (%d, %v), want (0, false)", budget, known)
	}
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 64}); known || budget != 0 {
		t.Fatalf("cold-missing-size = (%d, %v), want (0, false)", budget, known)
	}

	// Cold with memory + size data but NO post-load KV headroom (weights ~fill the
	// node): the estimate is 0 yet it is a KNOWN budget, not "unknown" — so the
	// gate can confidently reject rather than fail open.
	if budget, known := snapshotStructuralBudget(routingSnapshot{totalMemoryGB: 16, modelSizeGB: 14}); !known || budget != 0 {
		t.Fatalf("cold-no-headroom = (%d, %v), want (0, true)", budget, known)
	}
}

// TestPredictServableContextTier covers tier 1 (model context window), which is
// provider-agnostic, so it needs no registered providers.
func TestPredictServableContextTier(t *testing.T) {
	reg := New(testLogger())
	model := "ctx-model"

	// prompt 9000 + max 256 = 9256 > contextLimit 8192 → guaranteed-unservable.
	v := reg.PredictServable(model, 9000, 9000, 256, 8192, RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("over-context request reported servable: %+v", v)
	}
	if v.Reason != ServabilityContextExceeded {
		t.Fatalf("reason = %q, want %q", v.Reason, ServabilityContextExceeded)
	}
	if v.RequestTokens != 9256 {
		t.Fatalf("RequestTokens = %d, want 9256 (9000 prompt + 256 max)", v.RequestTokens)
	}
	if v.ContextLimit != 8192 {
		t.Fatalf("ContextLimit = %d, want 8192", v.ContextLimit)
	}

	// prompt 4000 + max 256 = 4256 <= contextLimit 131072 → context tier passes;
	// with an empty fleet the budget tier fails open → servable.
	v = reg.PredictServable(model, 4000, 4000, 256, 131072, RequestTraits{}, false)
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
	reg := New(testLogger())
	model := "budget-tier-model"
	// Two eligible providers with resident ("running") slots and known budgets;
	// the fleet ceiling is the larger of the two (8192).
	makeTokenBudgetProvider(t, reg, "big", model, 100, 0, 8192, 80)
	makeTokenBudgetProvider(t, reg, "small", model, 100, 0, 4096, 80)

	// prompt 20000 + max 256 = 20256 > fleet max 8192, and every provider's
	// budget is known → confident reject as prompt_too_long. contextLimit=0
	// disables tier 1.
	over := reg.PredictServable(model, 20000, 20000, 256, 0, RequestTraits{}, false)
	if over.Servable {
		t.Fatalf("over-budget request reported servable: %+v", over)
	}
	if over.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", over.Reason, ServabilityPromptTooLong)
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
	within := reg.PredictServable(model, 1000, 1000, 256, 0, RequestTraits{}, false)
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
	reg := New(testLogger())
	model := "context-prompt-isolation-model"
	makeTokenBudgetProvider(t, reg, "p", model, 100, 0, 8192, 80) // fleet max budget 8192

	// Budget tier (contextLimit=0 disables tier 1): raw 4000+256=4256 <= 8192
	// fits. A calibrated context-prompt of 9000 (9256 > 8192) must NOT leak into
	// the budget tier and shed it.
	budget := reg.PredictServable(model, 4000, 9000, 256, 0, RequestTraits{}, false)
	if !budget.Servable {
		t.Fatalf("calibrated context prompt leaked into the budget tier and over-rejected a budget-fitting request: %+v", budget)
	}
	if budget.RequestTokens != 4256 {
		t.Fatalf("RequestTokens = %d, want 4256 (budget tier must use the RAW estimate)", budget.RequestTokens)
	}

	// Context tier: raw 4000+256=4256 fits an 8192 context, but the calibrated
	// 9000+256=9256 exceeds it — the context tier DOES use the calibrated prompt.
	ctx := reg.PredictServable(model, 4000, 9000, 256, 8192, RequestTraits{}, false)
	if ctx.Servable || ctx.Reason != ServabilityContextExceeded {
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
	reg := New(testLogger())
	model := "fail-open-model"
	// One resident provider with NO reported active budget (legacy → unknown)...
	makeSchedulerProvider(t, reg, "legacy", model, 100)
	// ...alongside one with a small KNOWN budget. The unknown provider must
	// force fail-open regardless of the known ceiling.
	makeTokenBudgetProvider(t, reg, "known-small", model, 100, 0, 4096, 80)

	huge := reg.PredictServable(model, 1_000_000, 1_000_000, 256, 0, RequestTraits{}, false)
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
	reg := New(testLogger())
	model := "zero-budget-model"
	// 14 GB weights (padded ~15.6 GiB) + the activation reserve exceed 90% of a
	// 16 GB node, so coldTokenBudgetEstimate is 0 (a known zero). MinRAMGB 14 <= 16
	// keeps it past the hardware-fit gate (counted, not model_too_large).
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 14, MinRAMGB: 14}})
	makeWarmPoolColdProvider(t, reg, "tight", model, 80, 16, 0)

	v := reg.PredictServable(model, 1000, 1000, 256, 0, RequestTraits{}, false)
	if v.Servable {
		t.Fatalf("known-zero-budget fleet reported servable (must reject, not fail open): %+v", v)
	}
	if v.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", v.Reason, ServabilityPromptTooLong)
	}
	if v.ProviderCount != 1 {
		t.Fatalf("ProviderCount = %d, want 1 (cold node fits hardware, counted)", v.ProviderCount)
	}
	if v.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0 (known-zero cold budget)", v.FleetMaxBudget)
	}
}

// TestPredictServableMixedVersionFleetStagedRollout is the staged-rollout
// regression for the v0.8.0 activation-reserve raise: while the fleet is
// mixed, a COLD pre-0.8.0 provider still holds the old 3 GiB reserve, so its
// cold estimate must be charged 3 GiB — not the new global 5.5. A request
// sized BETWEEN the two estimates (fits the legacy box, not the upgraded one)
// must stay servable as long as any legacy box is eligible; once the whole
// fleet is ≥0.8.0 the same request is confidently shed as prompt_too_long.
func TestPredictServableMixedVersionFleetStagedRollout(t *testing.T) {
	const model = "rollout-model"
	// 64 GB boxes, 12 GB weights, default 400000 B/token:
	//   legacy (3 GiB reserve)  cold budget = 110565 tokens
	//   v0.8.0 (5.5 GiB reserve) cold budget = 103854 tokens
	// Request 105000 + 256 = 105256 sits strictly between the two.
	legacyBudget := coldTokenBudgetEstimate(64, 12, 0, "0.7.12", 0)
	newBudget := coldTokenBudgetEstimate(64, 12, 0, "0.8.0", 0)
	const reqPrompt, reqMax = 105000, 256
	if int64(reqPrompt+reqMax) <= newBudget || int64(reqPrompt+reqMax) > legacyBudget {
		t.Fatalf("fixture broke: request %d must sit between new budget %d and legacy budget %d",
			reqPrompt+reqMax, newBudget, legacyBudget)
	}

	setVersion := func(p *Provider, v string) {
		p.mu.Lock()
		p.Version = v
		p.mu.Unlock()
	}

	// Mixed fleet: one upgraded box, one legacy box, both COLD.
	mixed := New(testLogger())
	mixed.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12, MinRAMGB: 12}})
	setVersion(makeWarmPoolColdProvider(t, mixed, "upgraded", model, 80, 64, 0), "0.8.0")
	setVersion(makeWarmPoolColdProvider(t, mixed, "legacy", model, 80, 64, 0), "0.7.12")

	v := mixed.PredictServable(model, reqPrompt, reqPrompt, reqMax, 0, RequestTraits{}, false)
	if !v.Servable {
		t.Fatalf("mixed fleet falsely shed a request the legacy box can serve: %+v", v)
	}
	if v.FleetMaxBudget != legacyBudget {
		t.Fatalf("FleetMaxBudget = %d, want the legacy box's %d", v.FleetMaxBudget, legacyBudget)
	}
	if v.ProviderCount != 2 {
		t.Fatalf("ProviderCount = %d, want 2", v.ProviderCount)
	}

	// Fully upgraded fleet: the same request now exceeds every ceiling and is
	// confidently shed — the provider genuinely no longer has that KV room.
	upgraded := New(testLogger())
	upgraded.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12, MinRAMGB: 12}})
	setVersion(makeWarmPoolColdProvider(t, upgraded, "a", model, 80, 64, 0), "0.8.0")
	setVersion(makeWarmPoolColdProvider(t, upgraded, "b", model, 80, 64, 0), "0.8.1")

	shed := upgraded.PredictServable(model, reqPrompt, reqPrompt, reqMax, 0, RequestTraits{}, false)
	if shed.Servable {
		t.Fatalf("fully-upgraded fleet must shed the between-sized request: %+v", shed)
	}
	if shed.Reason != ServabilityPromptTooLong {
		t.Fatalf("reason = %q, want %q", shed.Reason, ServabilityPromptTooLong)
	}
	if shed.FleetMaxBudget != newBudget {
		t.Fatalf("FleetMaxBudget = %d, want %d", shed.FleetMaxBudget, newBudget)
	}
}

// TestPredictServableEmptyFleet proves an empty fleet is fail-open: zero
// eligible providers is a different rejection path, never prompt_too_long.
func TestPredictServableEmptyFleet(t *testing.T) {
	reg := New(testLogger())

	v := reg.PredictServable("no-such-model", 10_000_000, 10_000_000, 256, 0, RequestTraits{}, false)
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
