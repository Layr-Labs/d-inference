package registry

import "testing"

// Regression for the gemma-4 over-admission bug (v0.6.14): a bandwidth-bound
// model whose whole fleet decodes below the per-request quality floor still
// passed the capacity preflight, because freeMemoryAdmits keys on KV memory
// (which gemma never exhausts) and the decode floor was advisory-only. The
// coordinator then admitted far more requests than the fleet could serve at
// usable speed; they queued and timed out instead of being shed up front.
//
// These tests pin: (1) with the shed gate OFF (default), the preflight still
// counts the slow-but-memory-free provider as a candidate (over-admission — the
// pre-fix behavior, kept default for safety); (2) with the shed gate ON, the
// preflight rejects it on THROUGHPUT, yielding candidateCount==0 /
// capacityRejections>0 so the caller sheds with a fast 429.

// slowGemmaProvider: huge KV budget headroom (freeMemoryAdmits passes) but an
// observed decode TPS so low that the projected per-request rate is below the
// floor even with zero concurrent streams.
func slowGemmaProvider(t *testing.T, reg *Registry, id, model string, observedTPS float64) {
	t.Helper()
	// decodeTPS (static) high so only the OBSERVED rate drives the projection;
	// budget 1K used of 1M max ⇒ KV gate wide open (the gemma "never exhausts KV").
	makeTokenBudgetProvider(t, reg, id, model, 200, 1_000, 1_000_000, observedTPS)
}

func TestDecodeFloorShed_OffByDefault_AdmitsSlowFleet(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-slow"
	// Two providers, both decoding at ~8 tok/s observed — below the 15 floor.
	slowGemmaProvider(t, reg, "p1", model, 8)
	slowGemmaProvider(t, reg, "p2", model, 8)

	// Sanity: the projection is genuinely below the floor (so this is a real
	// "all-slow fleet", not a mis-set fixture).
	if got := projectedPerRequestDecodeTPS(routingSnapshot{observedDecodeTPS: 8, backendRunning: 0}); got >= 15 {
		t.Fatalf("fixture not slow enough: projected %.2f >= 15", got)
	}

	// Default: shed gate OFF → the slow fleet is still admissible (reproduces the
	// over-admission: candidateCount > 0 despite no provider meeting the floor).
	cc, capRej, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc == 0 {
		t.Fatalf("with shed OFF expected over-admission (candidateCount>0), got cc=%d capRej=%d", cc, capRej)
	}
}

func TestDecodeFloorShed_On_ShedsSlowFleet(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-slow"
	slowGemmaProvider(t, reg, "p1", model, 8)
	slowGemmaProvider(t, reg, "p2", model, 8)

	// Arm the shed gate at the 15 tok/s floor.
	reg.SetDecodeFloorShed(15, true)

	cc, capRej, tooLarge := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc != 0 {
		t.Fatalf("with shed ON expected candidateCount==0 (shed), got cc=%d", cc)
	}
	if capRej == 0 {
		t.Fatalf("with shed ON expected capacityRejections>0 (so caller 429s, not 503), got capRej=%d", capRej)
	}
	if tooLarge != 0 {
		t.Fatalf("slow providers must be capacity rejections, not model-too-large; tooLarge=%d", tooLarge)
	}
}

func TestDecodeFloorShed_On_StillAdmitsFastFleet(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-fast"
	// Fast providers (~40 tok/s observed) — comfortably above the floor.
	slowGemmaProvider(t, reg, "p1", model, 40)
	slowGemmaProvider(t, reg, "p2", model, 40)

	reg.SetDecodeFloorShed(15, true)

	// A healthy fleet must NOT be shed by the gate — guards against over-correcting.
	cc, capRej, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc == 0 {
		t.Fatalf("a fast fleet must remain admissible with shed ON; got cc=0 capRej=%d", capRej)
	}
}

func TestDecodeFloorShed_ZeroFloor_NoOp(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-slow"
	slowGemmaProvider(t, reg, "p1", model, 8)

	// hardShed true but floor 0 ⇒ disabled (matches MIN_DECODE_TPS=0 semantics):
	// must behave exactly like the off-by-default path (admit).
	reg.SetDecodeFloorShed(0, true)
	cc, _, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc == 0 {
		t.Fatalf("floor 0 must disable shedding (no-op); got cc=0")
	}
}
