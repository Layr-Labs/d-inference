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
	// And it must not be a PARTIAL shed (both fast providers stay candidates,
	// zero capacity rejections) — catches a subtly-wrong projection.
	if capRej != 0 {
		t.Fatalf("a fast fleet must have 0 capacity rejections with shed ON; got capRej=%d", capRej)
	}
	if cc != 2 {
		t.Fatalf("both fast providers must be candidates; got cc=%d", cc)
	}
}

// A freshly-warm provider that has not yet completed a request reports
// observedDecodeTPS==0; the projection then falls back to the STATIC benchmark
// decodeTPS. A healthy static TPS (here 200) must keep it above the floor — the
// shed gate must NOT punish a provider merely for having no observed sample yet.
func TestDecodeFloorShed_On_DoesNotShedFreshWarmProvider(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-fresh"
	// observedTPS 0 ⇒ projection uses static decodeTPS=200 (set by makeScheduler
	// Provider inside slowGemmaProvider) ⇒ ~157 tok/s projected, well above 15.
	slowGemmaProvider(t, reg, "p1", model, 0)
	reg.SetDecodeFloorShed(15, true)

	cc, _, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc == 0 {
		t.Fatalf("a fresh-warm provider (observed=0, static=200) must NOT be shed; got cc=0")
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

// Finding-1 regression: a memory/concurrency-full fleet (NOT a throughput shed)
// must NOT be classified as a decode-floor shed, even when the shed flag is
// armed. quickCapacityCheck folds concurrency, memory, and decode-floor failures
// into one capacityRejections counter; decodeFloorRejections is the throughput
// subset. The consumer bypasses queue-before-shed only when ALL rejections are
// throughput sheds, so a fast-but-full fleet must report
// decodeFloorRejections < capacityRejections and keep queueing.
func TestDecodeFloorShed_MemoryFullFastFleet_NotCountedAsThroughputShed(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-fast-full"
	// Budget exhausted (30K of 32K used; a 500+4096 request won't fit ⇒
	// freeMemoryAdmits fails ⇒ capacityRejection) but observed decode 40 tok/s
	// (well above any floor ⇒ NOT a decode-floor shed).
	makeTokenBudgetProvider(t, reg, "p1", model, 200, 30_000, 32_768, 40)

	reg.SetDecodeFloorShed(10, true) // shed armed

	cc, capRej, _, decodeFloorRej, _, _ := reg.quickCapacityCheck(model, 500, 4096, RequestTraits{}, false)
	if cc != 0 {
		t.Fatalf("a budget-full provider must not be a candidate; got cc=%d", cc)
	}
	if capRej == 0 {
		t.Fatalf("a budget-full provider must be a capacity rejection; got capRej=%d", capRej)
	}
	if decodeFloorRej != 0 {
		t.Fatalf("a FAST-but-full fleet must report 0 decode-floor rejections (so queue-before-shed still queues), got %d of %d capacity rejections", decodeFloorRej, capRej)
	}
}

// Mirror: a genuinely slow fleet rejected purely on throughput must report
// decodeFloorRejections == capacityRejections, so the consumer sheds immediately.
func TestDecodeFloorShed_SlowFleet_AllRejectionsAreThroughput(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-slow-pure"
	// Wide-open budget (1K of 1M) so freeMemoryAdmits passes; observed 8 tok/s so
	// the decode-floor gate is the ONLY thing that rejects.
	slowGemmaProvider(t, reg, "p1", model, 8)
	slowGemmaProvider(t, reg, "p2", model, 8)

	reg.SetDecodeFloorShed(10, true)

	cc, capRej, _, decodeFloorRej, _, _ := reg.quickCapacityCheck(model, 500, 4096, RequestTraits{}, false)
	if cc != 0 {
		t.Fatalf("a sub-floor fleet must be shed; got cc=%d", cc)
	}
	if decodeFloorRej == 0 || decodeFloorRej != capRej {
		t.Fatalf("a pure-throughput shed must have decodeFloorRejections==capacityRejections>0; got decodeFloor=%d cap=%d", decodeFloorRej, capRej)
	}
}

// The shed floor is DECOUPLED from the soft quality floor and defaults lower
// (shed 10 vs soft 15). A fleet decoding in the gap between them — too slow for
// the quality preference but not degraded enough to shed — must be admitted, not
// 429'd. This pins the decoupling that keeps a shed-floor of 15 (which the gemma
// telemetry showed would 429 a healthy uncontended fleet projecting ~15) from
// turning a latency problem into an availability outage.
func TestDecodeFloorShed_BetweenSoftAndShedFloor_Admits(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-mid"
	// Observed ~14 tok/s at backend_running=0 ⇒ projection ≈ 14/(1+0.27) ≈ 11.0:
	// below the soft quality bar (15) but above the shed floor (10).
	slowGemmaProvider(t, reg, "p1", model, 14)

	if got := projectedPerRequestDecodeTPS(routingSnapshot{observedDecodeTPS: 14, backendRunning: 0}); got < 10 || got >= 15 {
		t.Fatalf("fixture must land in the (10,15) gap; projected %.2f", got)
	}

	// Shed floor 10 (the new decoupled default), hard shed armed.
	reg.SetDecodeFloorShed(10, true)
	cc, capRej, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc == 0 {
		t.Fatalf("a fleet above the shed floor (10) must be admitted even when below the soft bar (15); got cc=0 capRej=%d", capRej)
	}
	if capRej != 0 {
		t.Fatalf("no capacity rejection expected above the shed floor; got capRej=%d", capRej)
	}

	// And the SAME fleet, were the shed floor mistakenly coupled back to 15,
	// WOULD be shed — proving the decoupling is load-bearing.
	reg.SetDecodeFloorShed(15, true)
	cc15, capRej15, _ := reg.QuickCapacityCheck(model, 500, 4096, RequestTraits{})
	if cc15 != 0 || capRej15 == 0 {
		t.Fatalf("control: a shed floor of 15 must shed this ~11-tok/s fleet; got cc=%d capRej=%d", cc15, capRej15)
	}
}
