package admission

import (
	"testing"
)

// TestColdTokenBudgetEstimate pins the pure cold post-load KV-budget estimator.
// The provider's activation reserve is a FLAT floor — it does not scale with
// context, batch, or attention posture (UnifiedMemoryCap
// .defaultActivationReserveBytes) — so this is one linear expression with no
// regimes and no crossover:
//
//	postLoadGB = servabilityCapFraction*total - size*coldLoadCatalogGBToMemGiB
//	postLoadB  = postLoadGB * BytesPerGiB
//	floorB     = floorGB * BytesPerGiB   // 5.5*2^30 (≥0.8.0) or 3*2^30 (legacy)
//	tokens     = (postLoadB - floorB) / kvBytesPerToken
//
// with servabilityCapFraction=0.90, coldLoadCatalogGBToMemGiB≈
// 1.1175870895385742, BytesPerGiB=1<<30, and kvBytesPerToken<=0 → 400000.
// floorGB is VERSION-GATED (ActivationFloor): the floor
// moved 3.0 → 5.5 with the provider's v0.8.0 B=8 reserve raise, so a ≥0.8.0
// provider's golden sits exactly 2.5*2^30/400000 = 6710.9 tokens below the
// legacy one, and nothing else moves — flat stays flat. An empty/pre-0.8.0
// version keeps the legacy 3 GiB floor (that is what those binaries hold).
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
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, v080, ""); got != wantRoomy {
		t.Fatalf("roomy estimate = %d, want %d", got, wantRoomy)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, v080, ""); got <= 0 {
		t.Fatalf("roomy estimate = %d, want > 0", got)
	}

	// (a1) The same box under a LEGACY binary: a pre-0.8.0 provider still
	// holds the old 3 GiB reserve, so its estimate is exactly 2.5*2^30/400000
	// = 6710.9 tokens higher — (47447529062.4 - 3221225472)/400000 = 110565.7.
	// An EMPTY (unreported) version fails toward the same legacy budget: the
	// larger estimate is the fail-open direction (see
	// ActivationFloor).
	const wantRoomyLegacy = int64(110565)
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, "0.7.12", ""); got != wantRoomyLegacy {
		t.Fatalf("legacy roomy estimate = %d, want %d", got, wantRoomyLegacy)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, "", ""); got != wantRoomyLegacy {
		t.Fatalf("unreported-version roomy estimate = %d, want %d (fail toward legacy)", got, wantRoomyLegacy)
	}
	// The gate is >= 0.8.0, not > 0.8.0, and later releases keep the floor.
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, "0.8.1", ""); got != wantRoomy {
		t.Fatalf("post-0.8.0 estimate = %d, want %d", got, wantRoomy)
	}

	// (b) Tiny node: weights (padded) alone exceed 90% of the 8 GB cap, so
	// there is no post-load memory at all, let alone room for the activation
	// reserve → 0 (never negative).
	if got := testPolicy.ColdTokenBudgetEstimate(8, 12, 400000, v080, ""); got != 0 {
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
	if got := testPolicy.ColdTokenBudgetEstimate(20, 14, 400000, v080, ""); got != 0 {
		t.Fatalf("reserve-bound estimate = %d, want 0 (weights fit, activation floor does not)", got)
	}

	// (b2) A 48 GB node loading 28 GB of gemma-4 weights. gemma-4 is the
	// COMPOSED-attention model (head_dim 256 sliding / 512 full, both outside
	// MLX's fused set), and it is charged exactly what fused gpt-oss is: the
	// flat floor, nothing more — because that is all the provider holds back.
	//   padded    = 28 * 1.1175870895385742      = 31.292438507080078
	//   postLoadGB= 0.90*48 - 31.292438507080078 = 11.907561492919925 GB
	//   tokens    = (11.907561492919925*2^30 - 5905580032) / 400000 = 17200.17
	if got := testPolicy.ColdTokenBudgetEstimate(48, 28, 400000, v080, ""); got != int64(17200) {
		t.Fatalf("gemma-4-shaped estimate = %d, want 17200", got)
	}
	// The same box under a legacy binary: 3 GiB floor →
	// (11.907561492919925*2^30 - 3221225472)/400000 = 23911.1.
	if got := testPolicy.ColdTokenBudgetEstimate(48, 28, 400000, "0.7.12", ""); got != int64(23911) {
		t.Fatalf("legacy gemma-4-shaped estimate = %d, want 23911", got)
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
		got := testPolicy.ColdTokenBudgetEstimate(total, 1, 400000, v080, "")
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

	// (c) kvBytesPerToken <= 0 falls back to the DefaultKVBytesPerToken default
	// (400000): an unreported per-model KV cost must match the explicit default,
	// for both a zero and a negative input.
	explicit := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, v080, "")
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 0, v080, ""); got != explicit {
		t.Fatalf("kvpt=0 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, -1, v080, ""); got != explicit {
		t.Fatalf("kvpt=-1 fallback estimate = %d, want %d (== explicit 400000)", got, explicit)
	}
	// A reported per-model KV cost is honored (and a cheaper per-token cost
	// yields strictly more tokens), proving the parameter is actually used.
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 200000, v080, ""); got <= explicit {
		t.Fatalf("cheaper kvpt estimate = %d, want > default-kvpt estimate %d", got, explicit)
	}

	// (d) Unusable inputs → 0 (gate disabled): no total memory, or no model size.
	if got := testPolicy.ColdTokenBudgetEstimate(0, 12, 400000, v080, ""); got != 0 {
		t.Fatalf("totalMemoryGB<=0 estimate = %d, want 0", got)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(-1, 12, 400000, v080, ""); got != 0 {
		t.Fatalf("totalMemoryGB<0 estimate = %d, want 0", got)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(64, 0, 400000, v080, ""); got != 0 {
		t.Fatalf("modelSizeGB<=0 estimate = %d, want 0", got)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(64, -1, 400000, v080, ""); got != 0 {
		t.Fatalf("modelSizeGB<0 estimate = %d, want 0", got)
	}
}

// TestColdTokenBudgetMirrorsProviderReserveArithmetic is the regression for the
// coordinator/provider activation-reserve desync.
//
// ColdTokenBudgetEstimate exists to reproduce ONE thing: the post-load KV budget
// UnifiedMemoryCap will actually leave a freshly-loaded slot. That budget is
// cap − paddedWeights − a FLAT 5.5 GiB reserve, and once the slot is resident the
// provider reports precisely it back as active_token_budget_max
// (EngineV2Bridge+Capacity: kvBytesCapacity / kvBytesPerToken), which
// StructuralBudget then prefers. The cold estimate must therefore
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
		got := testPolicy.ColdTokenBudgetEstimate(tc.totalMemoryGB, tc.modelSizeGB, 400000, "0.8.0", "")
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
	// load, which dispatch retries elsewhere. Convergence is PER-BINARY: a
	// ≥0.8.0 provider is mirrored against the 5.5 GiB gate its binary holds,
	// a pre-0.8.0 provider against its 3 GiB gate.
	for _, totalGB := range []float64{24, 36, 48, 64, 96, 128, 192, 512} {
		for _, sizeGB := range []float64{1, 12, 20, 28, 40} {
			got := testPolicy.ColdTokenBudgetEstimate(totalGB, sizeGB, 400000, "0.8.0", "")
			want := providerPostLoadTokenBudget(totalGB, sizeGB, 400000, 5.5)
			if got < want {
				t.Fatalf("total=%.0fGB size=%.0fGB: cold estimate %d is TIGHTER than the provider's %d",
					totalGB, sizeGB, got, want)
			}
			legacyGot := testPolicy.ColdTokenBudgetEstimate(totalGB, sizeGB, 400000, "0.7.12", "")
			legacyWant := providerPostLoadTokenBudget(totalGB, sizeGB, 400000, 3.0)
			if legacyGot < legacyWant {
				t.Fatalf("total=%.0fGB size=%.0fGB: LEGACY cold estimate %d is TIGHTER than the pre-0.8.0 provider's %d",
					totalGB, sizeGB, legacyGot, legacyWant)
			}
		}
	}
}

// providerPostLoadTokenBudget recomputes the PROVIDER's post-load KV token
// budget from the provider's own constants, in bytes throughout — deliberately
// not sharing ColdTokenBudgetEstimate's GB-then-bytes ordering:
//
//	UnifiedMemoryCap.kvBudgetBytes = 0.90*physical − paddedWeights − reserve
//	active_token_budget_max        = kvBudgetBytes / kvBytesPerToken
//
// reserveGB is spelled as a literal at each CALL SITE (5.5 for ≥0.8.0 —
// UnifiedMemoryCap.defaultActivationReserveBytes — and 3.0 for the pre-0.8.0
// binaries still in the fleet) rather than read from the servability
// constants, on purpose: if one side's reserve is retuned and the other is
// not, those literals are what fail — as they did (by design) when the
// provider moved 3 → 5.5 for v0.8.0's B=8 activation peak, forcing this file
// to move with it. (BytesPerGiB and coldLoadCatalogGBToMemGiB are shared
// because they are unit conversions, not policy.)
func providerPostLoadTokenBudget(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64, reserveGB float64) int64 {
	reserveBytes := reserveGB * float64(BytesPerGiB)
	capBytes := 0.90 * totalMemoryGB * float64(BytesPerGiB)
	weightBytes := modelSizeGB * coldLoadCatalogGBToMemGiB * float64(BytesPerGiB)
	free := capBytes - weightBytes - reserveBytes
	if free <= 0 {
		return 0
	}
	return int64(free / float64(kvBytesPerToken))
}

// TestSnapshotStructuralBudget pins how a single provider's snapshot maps to a
// structural token budget and whether that budget is known (fail-open) per the
// three branches in StructuralBudget.
func TestSnapshotStructuralBudget(t *testing.T) {
	// Resident slot with a reported active budget: authoritative and known.
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{ActiveTokenBudgetMax: 8192})); !known || budget != 8192 {
		t.Fatalf("resident-with-budget = (%d, %v), want (8192, true)", budget, known)
	}

	// The reported active budget wins even when memory/size data is also present
	// (it must NOT fall through to the cold estimate for a loaded model).
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{
		ActiveTokenBudgetMax: 8192,
		ModelLoaded:          true,
		TotalMemoryGB:        64,
		ModelSizeGB:          12,
	})); !known || budget != 8192 {
		t.Fatalf("resident-with-budget+mem = (%d, %v), want (8192, true)", budget, known)
	}

	// Resident but no budget reported (legacy provider): unknown → fail-open.
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{ModelLoaded: true})); known || budget != 0 {
		t.Fatalf("resident-no-budget = (%d, %v), want (0, false)", budget, known)
	}

	// Cold/on-disk with memory + size data: known, using the optimistic cold
	// estimate. Unreported kvBytesPerToken falls back to the 400000 default;
	// an unreported binaryVersion falls toward the legacy reserve.
	wantCold := testPolicy.ColdTokenBudgetEstimate(64, 12, 0, "", "")
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{TotalMemoryGB: 64, ModelSizeGB: 12})); !known || budget != wantCold {
		t.Fatalf("cold-fitting = (%d, %v), want (%d, true)", budget, known, wantCold)
	}
	// A cold slot threads its reported per-model KV cost into the estimate.
	wantColdKVPT := testPolicy.ColdTokenBudgetEstimate(64, 12, 200000, "", "")
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{
		TotalMemoryGB:   64,
		ModelSizeGB:     12,
		KVBytesPerToken: 200000,
	})); !known || budget != wantColdKVPT {
		t.Fatalf("cold-fitting+kvpt = (%d, %v), want (%d, true)", budget, known, wantColdKVPT)
	}
	// A cold slot threads its provider's binary version into the estimate:
	// a ≥0.8.0 binary is charged the 5.5 GiB reserve it actually holds,
	// which lands strictly below the legacy default above.
	wantColdV080 := testPolicy.ColdTokenBudgetEstimate(64, 12, 0, "0.8.0", "")
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{
		TotalMemoryGB: 64,
		ModelSizeGB:   12,
		BinaryVersion: "0.8.0",
	})); !known || budget != wantColdV080 {
		t.Fatalf("cold-fitting+version = (%d, %v), want (%d, true)", budget, known, wantColdV080)
	}
	if wantColdV080 >= wantCold {
		t.Fatalf("v0.8.0 cold budget %d must sit below the legacy cold budget %d (bigger reserve)",
			wantColdV080, wantCold)
	}

	// Cold but missing memory or size data: cannot estimate → unknown.
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{ModelSizeGB: 12})); known || budget != 0 {
		t.Fatalf("cold-missing-memory = (%d, %v), want (0, false)", budget, known)
	}
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{TotalMemoryGB: 64})); known || budget != 0 {
		t.Fatalf("cold-missing-size = (%d, %v), want (0, false)", budget, known)
	}

	// Cold with memory + size data but NO post-load KV headroom (weights ~fill the
	// node): the estimate is 0 yet it is a KNOWN budget, not "unknown" — so the
	// gate can confidently reject rather than fail open.
	if budget, known := testPolicy.StructuralBudget(snapPtr(Snapshot{TotalMemoryGB: 16, ModelSizeGB: 14})); !known || budget != 0 {
		t.Fatalf("cold-no-headroom = (%d, %v), want (0, true)", budget, known)
	}
}

// TestServabilityActivationFloorPerModel pins the (version, model)-gated floor
// selection. Three regimes, mirroring what each provider binary actually holds
// (UnifiedMemoryCap.resolvedActivationReserveBytes):
//
//   - < 0.8.0 (or unreported): the legacy flat 3 GiB reserve, any model.
//   - 0.8.0 ..< perModel: the flat 5.5 GiB reserve, any model.
//   - >= perModel: the measured per-model floor for models in the mirrored
//     table (gpt-oss-20b: 3.5 = worst measured B=8 peak, 3.20 GiB compiled,
//   - slack), the flat 5.5 otherwise. The table mirrors
//     UnifiedMemoryCap.measuredActivationFloorsBytes and the two MUST move in
//     the same commit.
//
// The per-model figure is a LOWER bound on the reserve a multi-model provider
// holds (its UnifiedMemoryCap takes the max over its whole serving set, which
// the coordinator does not know) — the optimistic direction this file
// sanctions: worst case is a declined load the dispatch path retries, and the
// warm report replaces the estimate as soon as the slot loads.
func TestServabilityActivationFloorPerModel(t *testing.T) {
	cases := []struct {
		version, model string
		want           float64
	}{
		{"", "gpt-oss-20b", 3.0},                                                  // unreported → legacy floor
		{"0.7.12", "gpt-oss-20b", 3.0},                                            // legacy binary → legacy floor
		{"0.8.0", "gpt-oss-20b", 5.5},                                             // flat-floor binary, measured model
		{"0.8.10", "gpt-oss-20b", 5.5},                                            // flat-floor release
		{"0.8.15", "gpt-oss-20b", 5.5},                                            // last flat-floor release actually shipped
		{servabilityPerModelFloorMinVersion, "gpt-oss-20b", 3.5},                  // measured floor
		{servabilityPerModelFloorMinVersion, "qwen3.6-35b-a3b-vl-mtp-mxfp8", 5.5}, // vision-capable → default until vision-inclusive measurement
		{servabilityPerModelFloorMinVersion, "qwen3.5-35b-a3b", 5.5},              // vision-capable → default
		{servabilityPerModelFloorMinVersion, "gemma-4-26b", 5.5},                  // unmeasured → flat
		{servabilityPerModelFloorMinVersion, "", 5.5},                             // unknown model → flat
		{"0.9.0", "gpt-oss-20b", 3.5},                                             // later releases keep the table
		{"0.8.10", "qwen3.6-35b-a3b-vl-mtp-mxfp8", 5.5},                           // flat-floor binary even for a measured model
	}
	for _, tc := range cases {
		if got := testPolicy.ActivationFloor(tc.version, tc.model); got != tc.want {
			t.Fatalf("servabilityActivationFloor(%q, %q) = %v, want %v",
				tc.version, tc.model, got, tc.want)
		}
	}
}

// TestColdTokenBudgetEstimatePerModelFloor pins the cold estimate under the
// per-model floor. Same roomy node as TestColdTokenBudgetEstimate (total=64,
// size=12, kvpt=400000, postLoadB = 47447529062.4):
//
//	gpt-oss-20b @ perModel (MEASURED weights 11.5 GiB + measured floor 3.5):
//	  (0.9*64 - 11.5)*2^30 = 49499480063.6... exact: 46.1*2^30 = 49499498086.4
//	  (49499498086.4 - 3758096384)/400000 = 114353.50
//	unmeasured-in-both-tables @ perModel (padded weights + flat floor):
//	  (47447529062.4 - 5.5*2^30)/400000 = 103854.87
func TestColdTokenBudgetEstimatePerModelFloor(t *testing.T) {
	v := servabilityPerModelFloorMinVersion
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, v, "gpt-oss-20b"); got != int64(114353) {
		t.Fatalf("per-model gpt-oss estimate = %d, want 114353 (measured weights + floor)", got)
	}
	// gemma-4-26b-qat-4bit sits in NEITHER table (vision-capable → no measured
	// residency; no measured activation floor): padded weights + flat floor.
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, v, "gemma-4-26b-qat-4bit"); got != int64(103854) {
		t.Fatalf("per-model dual-unmeasured estimate = %d, want 103854 (padded + flat floor)", got)
	}
	// A pre-perModel binary holds the FLAT reserve AND padded weights even for
	// a measured model.
	if got := testPolicy.ColdTokenBudgetEstimate(64, 12, 400000, "0.8.10", "gpt-oss-20b"); got != int64(103854) {
		t.Fatalf("pre-perModel gpt-oss estimate = %d, want 103854 (padded + flat floor)", got)
	}
}

// TestServabilityColdWeightsPerModel pins the (version, model)-gated weights
// term: measured resident GiB for ≥perModel binaries on measured text-only
// models, the catalog-padded conversion otherwise. Vision-capable models are
// deliberately absent from the measured table (text-only bench residency
// under-counts their towers) and must keep the padded figure.
func TestServabilityColdWeightsPerModel(t *testing.T) {
	v := servabilityPerModelFloorMinVersion
	padded := func(sz float64) float64 { return sz * coldLoadCatalogGBToMemGiB }
	cases := []struct {
		version, model string
		catalogSizeGB  float64
		want           float64
	}{
		{"", "gemma-4-26b-8bit", 28.0, padded(28.0)},            // unreported → padded
		{"0.8.15", "gemma-4-26b-8bit", 28.0, padded(28.0)},      // flat-era binary → padded
		{v, "gemma-4-26b-8bit", 28.0, padded(28.0)},             // VLM artifact → padded pending provider-path measurement
		{v, "gemma-4-26b", 28.0, padded(28.0)},                  // VLM artifact → padded
		{v, "gpt-oss-20b", 12.1, 11.5},                          // measured residency (text-only artifact)
		{v, "qwen3.6-35b-a3b-vl-mtp-mxfp8", 21.3, padded(21.3)}, // vision-capable → padded
		{v, "unknown-model", 10.0, padded(10.0)},                // unmeasured → padded
	}
	for _, tc := range cases {
		if got := testPolicy.ColdWeightsGiB(tc.version, tc.model, tc.catalogSizeGB); got != tc.want {
			t.Fatalf("servabilityColdWeightsGiB(%q, %q, %v) = %v, want %v",
				tc.version, tc.model, tc.catalogSizeGB, got, tc.want)
		}
	}

	// gemma-8bit stays padded (VLM artifact) in EVERY regime for now — the
	// 36 GB tier unblock is gated on a provider-path residency measurement:
	if got := testPolicy.ColdTokenBudgetEstimate(36, 28, 400000, "0.8.15", "gemma-4-26b-8bit"); got != 0 {
		t.Fatalf("flat-era gemma-8bit@36 estimate = %d, want 0 (padded weights bust the box)", got)
	}
	if got := testPolicy.ColdTokenBudgetEstimate(36, 28, 400000, v, "gemma-4-26b-8bit"); got != 0 {
		t.Fatalf("perModel gemma-8bit@36 estimate = %d, want 0 (still padded pending VLM-path measurement)", got)
	}
	// The measured text-only model DOES take the measured figure in the
	// POST-load estimate: gpt-oss on a 24 GB box gains the difference
	// (padded 13.53 vs measured 11.5).
	if got, want := testPolicy.ColdTokenBudgetEstimate(24, 12.1, 400000, v, "gpt-oss-20b"),
		testPolicy.ColdTokenBudgetEstimate(24, 12.1, 400000, "0.8.15", "gpt-oss-20b"); got <= want {
		t.Fatalf("perModel gpt-oss@24 estimate = %d, want > flat-era %d (measured weights + floor)", got, want)
	}
	// The ADMIT gate, by contrast, charges the PADDED figure for EVERY
	// binary and model — the load transient exceeds steady residency, so
	// a measured-weights admit would over-admit loads that OOM mid-staging.
	free := 12.0 // fits measured 11.5, NOT padded 13.53
	if admit, reported := ReportedFreeForLoadAdmits(12.1, &free); !reported || admit {
		t.Fatalf("admit gate = (%v, %v), want (false, true): padded transient figure must govern admits", admit, reported)
	}
	roomy := 14.0 // fits padded 13.53
	if admit, reported := ReportedFreeForLoadAdmits(12.1, &roomy); !reported || !admit {
		t.Fatalf("admit gate = (%v, %v), want (true, true)", admit, reported)
	}
}
