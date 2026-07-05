package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestTokenBudgetAdmissionRejectsFullProvider(t *testing.T) {
	reg := New(testLogger())
	model := "budget-model"

	// Provider with budget nearly full: 30K used of 32K max.
	makeTokenBudgetProvider(t, reg, "full", model, 100, 30_000, 32_768, 80)
	// Provider with plenty of budget: 4K used of 32K max.
	makeTokenBudgetProvider(t, reg, "empty", model, 100, 4_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-budget",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    4096,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	if selected.ID != "empty" {
		t.Fatalf("selected %q, want 'empty' (more budget headroom)", selected.ID)
	}
}

func TestTokenBudgetAdmissionRejectsWhenOverBudget(t *testing.T) {
	reg := New(testLogger())
	model := "overbudget-model"

	// Single provider with 31K used of 32K budget. Request needs 500+4096 = 4596 tokens.
	makeTokenBudgetProvider(t, reg, "full", model, 100, 31_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-over",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    4096,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("expected nil (over budget), got provider %q", selected.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Fatalf("CapacityRejections=%d, want 1", decision.CapacityRejections)
	}
}

func TestTokenBudgetAdmissionCountsPendingPromptAndMaxTokens(t *testing.T) {
	reg := New(testLogger())
	model := "pending-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 0, 5_000, 80)
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	req := &PendingRequest{
		RequestID:             "new",
		Model:                 model,
		EstimatedPromptTokens: 1_000,
		RequestedMaxTokens:    256,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("selected %q, want nil because pending prompt+max exhausts budget", selected.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Fatalf("CapacityRejections=%d, want 1", decision.CapacityRejections)
	}
}

func TestQuickCapacityCheckCountsPendingPromptAndMaxTokens(t *testing.T) {
	reg := New(testLogger())
	model := "quick-pending-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 0, 5_000, 80)
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 1_000, 256, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestTokenBudgetDoesNotDoubleCountBackendQueuedBudget(t *testing.T) {
	reg := New(testLogger())
	model := "queued-overlap-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 1_000, 5_000, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxTokensPotential = 1_000
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 3_000
	p.mu.Unlock()
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	req := &PendingRequest{
		RequestID:             "new",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("selected nil, want provider; decision=%+v", decision)
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

func TestObservedTPSPreferredOverBenchmark(t *testing.T) {
	reg := New(testLogger())
	model := "tps-model"

	// Provider A: high benchmark TPS but low observed TPS (under load).
	makeTokenBudgetProvider(t, reg, "bench-fast", model, 200, 0, 32_768, 30)
	// Provider B: lower benchmark TPS but higher observed TPS (lightly loaded).
	makeTokenBudgetProvider(t, reg, "bench-slow", model, 50, 0, 32_768, 70)

	req := &PendingRequest{
		RequestID:             "req-tps",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    2048,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	// Provider B has higher observed TPS (70 vs 30), so its thisReqMs is lower.
	if selected.ID != "bench-slow" {
		t.Fatalf("selected %q, want 'bench-slow' (higher observed TPS)", selected.ID)
	}
	if decision.EffectiveTPS <= 0 {
		t.Fatalf("EffectiveTPS=%f, want > 0", decision.EffectiveTPS)
	}
}

func TestTokenBudgetBacklogCost(t *testing.T) {
	reg := New(testLogger())
	model := "backlog-model"

	// Provider A: large backlog (20K tokens used).
	makeTokenBudgetProvider(t, reg, "heavy", model, 100, 20_000, 32_768, 80)
	// Provider B: light backlog (2K tokens used).
	makeTokenBudgetProvider(t, reg, "light", model, 100, 2_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-backlog",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	if selected.ID != "light" {
		t.Fatalf("selected %q, want 'light' (lower backlog)", selected.ID)
	}
	if decision.BacklogMs <= 0 {
		t.Fatalf("BacklogMs=%f, want > 0 (should reflect token backlog)", decision.BacklogMs)
	}
}

func TestMaxConcurrencyRaisedWithTokenBudget(t *testing.T) {
	reg := New(testLogger())
	model := "concurrency-model"

	p := makeTokenBudgetProvider(t, reg, "budget-provider", model, 100, 0, 32_768, 80)
	if got := p.MaxConcurrency(); got != 24 {
		t.Fatalf("MaxConcurrency()=%d, want 24 (token budget reported)", got)
	}
}

func TestMaxConcurrencyFallsBackWithoutTokenBudget(t *testing.T) {
	reg := New(testLogger())
	model := "legacy-model"

	// Provider without token budget fields (legacy behavior).
	p := makeSchedulerProvider(t, reg, "legacy", model, 100)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 48
	p.mu.Unlock()

	if got := p.MaxConcurrency(); got != 4 {
		t.Fatalf("MaxConcurrency()=%d, want 4 (48GB legacy tier)", got)
	}
}

func TestPerSlotMaxConcurrencyLimitsRoutingForModel(t *testing.T) {
	reg := New(testLogger())
	model := "slot-capped-model"
	p := makeSchedulerProvider(t, reg, "capped", model, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 1
	p.mu.Unlock()

	first := &PendingRequest{RequestID: "req-first", Model: model, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(model, first); selected == nil {
		t.Fatal("first request should route")
	}

	second := &PendingRequest{RequestID: "req-second", Model: model, RequestedMaxTokens: 128}
	selected, decision := reg.ReserveProviderEx(model, second)
	if selected != nil {
		t.Fatalf("second request selected %q, want nil at per-slot cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection at per-slot cap", decision)
	}

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestPerSlotMaxConcurrencyZeroFallsBack(t *testing.T) {
	reg := New(testLogger())
	model := "slot-zero-model"
	p := makeSchedulerProvider(t, reg, "fallback", model, 100)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].MaxConcurrency = 0
	p.mu.Unlock()

	if got := p.MaxConcurrencyForModel(model); got != 6 {
		t.Fatalf("MaxConcurrencyForModel()=%d, want fallback 6", got)
	}
	for i := range 4 {
		p.AddPending(&PendingRequest{RequestID: fmt.Sprintf("existing-%d", i), Model: model})
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 1/0", candidates, rejections)
	}
}

// TestQuickCapacityCheckReportsModelTooLarge is the preflight half of the
// model_too_large fix: a cold model that can never fit must be reported as
// modelTooLarge, NOT capacityRejections — otherwise the consumer preflight 429s
// it and the client retries a model that will never fit. Regression for the
// Codex review finding on the QuickCapacityCheck preflight.
func TestQuickCapacityCheckReportsModelTooLarge(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-too-large"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 128}}) // needs 128*2=256GB
	p := makeSchedulerProvider(t, reg, "small-box", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle_shutdown" // cold: model not resident
	p.mu.Unlock()

	candidates, rejections, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 0 || tooLarge != 1 {
		t.Fatalf("QuickCapacityCheck = (cand=%d, rej=%d, tooLarge=%d), want 0/0/1", candidates, rejections, tooLarge)
	}
}

// TestModelFitPrefersCatalogMinRAM is the core fix: the fit gate must use the
// catalog's authoritative min_ram_gb, NOT a synthetic multiple of the weight.
// A 28 GB-weight model (gemma-like) with min_ram_gb=36 must be ADMITTED on a
// 64 GB box (a multiplier of 2.x would have wrongly rejected the whole 64 GB
// tier), and REJECTED on a 24 GB box (below the published minimum).
func TestModelFitPrefersCatalogMinRAM(t *testing.T) {
	model := "gemma-like"
	// Qualifies on 64 GB (min_ram_gb=36 ≤ 64).
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	p := makeSchedulerProvider(t, reg, "box64", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle_shutdown" // cold: gate applies
	p.mu.Unlock()
	if _, _, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 0 {
		t.Fatalf("min_ram_gb=36 on 64GB box must be admitted, got modelTooLarge=%d", tooLarge)
	}

	// Rejected on 24 GB (below min_ram_gb=36).
	reg2 := New(testLogger())
	reg2.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	small := makeSchedulerProvider(t, reg2, "box24", model, 80)
	small.mu.Lock()
	small.BackendCapacity.TotalMemoryGB = 24
	small.BackendCapacity.Slots[0].State = "idle_shutdown"
	small.mu.Unlock()
	if _, _, tooLarge := reg2.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 1 {
		t.Fatalf("min_ram_gb=36 on 24GB box must be model_too_large, got %d", tooLarge)
	}
}

// TestModelFitGptOssOn24GB is the operator-facing case: gpt-oss-20b
// (min_ram_gb=24) must be ADMITTED on a 24 GB box — the catalog says it
// qualifies, and a weight×multiplier gate (12.1×2.x > 24) would wrongly reject
// it and starve every 24 GB node of traffic.
func TestModelFitGptOssOn24GB(t *testing.T) {
	reg := New(testLogger())
	model := "gpt-oss-20b"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12.1, MinRAMGB: 24}})
	p := makeSchedulerProvider(t, reg, "box24", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 24
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.mu.Unlock()
	if _, _, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 0 {
		t.Fatalf("gpt-oss-20b (min_ram_gb=24) on a 24GB box must be admitted, got modelTooLarge=%d", tooLarge)
	}
}

func TestPerSlotMaxConcurrencyUsesBackendReportedLoad(t *testing.T) {
	reg := New(testLogger())
	model := "backend-loaded-model"
	p := makeSchedulerProvider(t, reg, "backend-loaded", model, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 1
	p.BackendCapacity.Slots[0].NumRunning = 1
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-over-backend-cap",
		Model:              model,
		RequestedMaxTokens: 128,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil at backend-reported slot cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection from backend slot load", decision)
	}

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestManyPerSlotCapsRespectProviderWideAggregateCap(t *testing.T) {
	reg := New(testLogger())
	models := make([]string, 0, 8)
	for i := range 8 {
		models = append(models, fmt.Sprintf("aggregate-cap-model-%d", i))
	}
	p := makeSchedulerProvider(t, reg, "aggregate-cap", models[0], 100)
	p.mu.Lock()
	p.Models = p.Models[:0]
	p.BackendCapacity.Slots = p.BackendCapacity.Slots[:0]
	for _, model := range models {
		p.Models = append(p.Models, protocol.ModelInfo{ID: model, ModelType: "chat", Quantization: "4bit"})
		p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
			Model:                model,
			State:                "running",
			MaxConcurrency:       8,
			ActiveTokenBudgetMax: 32_768,
		})
	}
	p.mu.Unlock()

	for i := range 24 {
		p.AddPending(&PendingRequest{
			RequestID:          fmt.Sprintf("existing-%d", i),
			Model:              models[i%len(models)],
			RequestedMaxTokens: 128,
		})
	}

	selected, decision := reg.ReserveProviderEx(models[0], &PendingRequest{
		RequestID:             "req-over-aggregate-cap",
		Model:                 models[0],
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil at provider-wide aggregate cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection at aggregate cap", decision)
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(models[0], 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestModelCapacitySnapshotRespectsPerSlotMaxConcurrency(t *testing.T) {
	reg := New(testLogger())
	modelA := "snapshot-full-model"
	modelB := "snapshot-open-model"
	p := makeSchedulerProvider(t, reg, "snapshot-provider", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 1, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, MaxConcurrency: 2},
	}
	p.mu.Unlock()

	snapshots := reg.ModelCapacitySnapshot()
	byModel := make(map[string]ModelCapacity, len(snapshots))
	for _, snap := range snapshots {
		byModel[snap.ModelID] = snap
	}

	full, ok := byModel[modelA]
	if !ok {
		t.Fatalf("missing snapshot for %s", modelA)
	}
	if full.Ready || full.CanAccept || full.RoutableProviders != 0 {
		t.Fatalf("full model snapshot=%+v, want not ready/routable", full)
	}
	if full.ActiveRequests != 1 {
		t.Fatalf("full model active_requests=%d, want 1", full.ActiveRequests)
	}

	open, ok := byModel[modelB]
	if !ok {
		t.Fatalf("missing snapshot for %s", modelB)
	}
	if !open.Ready || !open.CanAccept || open.RoutableProviders != 1 {
		t.Fatalf("open model snapshot=%+v, want ready with one routable provider", open)
	}
}
