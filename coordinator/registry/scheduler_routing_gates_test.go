package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// QuickCapacityCheck must mirror the routing path's per-provider gates: for a
// tools request it must exclude (a) a pair in the shape-keyed inference-error
// cooldown for the tools shape and (b) a trait-ineligible provider (below the
// tools floor or render-broken). Without this the preflight reports phantom
// capacity that routing then refuses, queueing the request to a misleading 429.
func TestQuickCapacityCheckExcludesShapeCooledAndTraitIneligible(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-tools-model"
	toolTraits := RequestTraits{HasTools: true}

	// All providers at/above the tools floor unless stated; render verdict nil.
	cooled := makeSchedulerProvider(t, reg, "cooled", model, 100)
	belowFloor := makeSchedulerProvider(t, reg, "below-floor", model, 100)
	renderBroken := makeSchedulerProvider(t, reg, "render-broken", model, 100)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 100)
	setProviderVersion(cooled, "0.6.5")
	setProviderVersion(belowFloor, "0.6.2") // below the 0.6.3 tools floor
	setProviderVersion(renderBroken, "0.6.5")
	setProviderVersion(healthy, "0.6.5")
	renderBroken.mu.Lock()
	renderBroken.Models[0].TemplateRenderOK = boolPtr(false)
	renderBroken.mu.Unlock()

	// Quarantine the "cooled" provider for the TOOLS shape only.
	reg.RecordInferenceError(cooled.ID, model, 500, "tools")
	if !reg.RecordInferenceError(cooled.ID, model, 500, "tools") {
		t.Fatal("two tools strikes should trip the tools cooldown")
	}

	// For a TOOLS request, only the healthy provider is a candidate.
	candidates, rejections, tooLarge := reg.QuickCapacityCheck(model, 100, 128, toolTraits)
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("tools QuickCapacityCheck = (cand=%d rej=%d tooLarge=%d), want 1/0/0 (only healthy)", candidates, rejections, tooLarge)
	}

	// For a BASE request, the tools cooldown and tools floor do not apply, so the
	// cooled, below-floor, and healthy providers all qualify — but render-broken
	// is still excluded for every shape.
	baseCandidates, baseRej, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if baseCandidates != 3 || baseRej != 0 {
		t.Fatalf("base QuickCapacityCheck = (cand=%d rej=%d), want 3/0 (render-broken excluded; tools gates inactive)", baseCandidates, baseRej)
	}
}

// Render-broken must fence a NON-tool request too: a crashing chat template
// breaks every request shape, so a base request must skip the render-broken
// provider and only the healthy one remains a candidate.
func TestQuickCapacityCheckExcludesRenderBrokenForBaseRequest(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-render-broken-base"
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 100)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 100)
	broken.mu.Lock()
	broken.Models[0].TemplateRenderOK = boolPtr(false)
	broken.mu.Unlock()
	healthy.mu.Lock()
	healthy.Models[0].TemplateRenderOK = boolPtr(true)
	healthy.mu.Unlock()

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("base QuickCapacityCheck = (cand=%d rej=%d), want 1/0 (render-broken fenced for base too)", candidates, rejections)
	}
}

// Scheduler integration: a render-broken provider must be excluded from a
// NON-tool ReserveProviderEx too — the routing path, not just the preflight,
// fences every shape.
func TestReserveProviderExSkipsRenderBrokenForBaseRequest(t *testing.T) {
	reg := New(testLogger())
	model := "render-broken-base-route"
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 200)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 50)
	broken.mu.Lock()
	broken.Models[0].TemplateRenderOK = boolPtr(false)
	broken.mu.Unlock()
	healthy.mu.Lock()
	healthy.Models[0].TemplateRenderOK = boolPtr(true)
	healthy.mu.Unlock()

	plain := &PendingRequest{RequestID: "r-plain", Model: model, RequestedMaxTokens: 128}
	selected, decision := reg.ReserveProviderEx(model, plain)
	if selected == nil || selected.ID != healthy.ID {
		t.Fatalf("plain request selected %v, want %q (render-broken excluded for all shapes)", selected, healthy.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (render-broken fenced for base too)", decision.CandidateCount)
	}
}

// QuickCapacityCheck must honor allowedSerials: a capable-but-not-allowed
// provider does not satisfy the preflight for a constrained request.
func TestQuickCapacityCheckHonorsAllowedSerials(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-allowed-serial"
	allowed := makeSchedulerProvider(t, reg, "allowed", model, 100)
	other := makeSchedulerProvider(t, reg, "other", model, 100)
	setSchedulerProviderSerial(allowed, "ALLOWED-SERIAL")
	setSchedulerProviderSerial(other, "OTHER-SERIAL")

	// Unconstrained: both qualify.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); c != 2 {
		t.Fatalf("unconstrained candidates=%d, want 2", c)
	}
	// Constrained to ALLOWED-SERIAL: only that provider qualifies.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}, "ALLOWED-SERIAL"); c != 1 {
		t.Fatalf("constrained candidates=%d, want 1 (only the allowed serial)", c)
	}
	// Constrained to a serial nobody has: zero candidates.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}, "MISSING-SERIAL"); c != 0 {
		t.Fatalf("missing-serial candidates=%d, want 0", c)
	}
}

// HasToolCapableProviderForModel and HasVisionProviderForModel must honor
// allowedSerials: a capable provider whose serial is not in the allowed set
// does NOT satisfy the check, so a constrained request is not falsely reported
// as serviceable by an unrelated public provider.
func TestCapabilityChecksHonorAllowedSerials(t *testing.T) {
	reg := New(testLogger())
	model := "capability-allowed-serial"

	// One tool-capable + vision-capable provider, serial NOT in the allowlist.
	capable := makeSchedulerProvider(t, reg, "capable-not-allowed", model, 100)
	setProviderVersion(capable, "0.6.5")
	setSchedulerProviderSerial(capable, "CAPABLE-SERIAL")
	capable.mu.Lock()
	capable.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	capable.mu.Unlock()

	// Unconstrained: both capabilities satisfied.
	if !reg.HasToolCapableProviderForModel(model) {
		t.Fatal("unconstrained: expected a tool-capable provider")
	}
	if !reg.HasVisionProviderForModel(model) {
		t.Fatal("unconstrained: expected a vision-capable provider")
	}

	// Constrained to a serial the capable provider does NOT have: neither check
	// may be satisfied by it.
	if reg.HasToolCapableProviderForModel(model, "ALLOWED-ONLY") {
		t.Fatal("a tool-capable but not-allowed provider must not satisfy a constrained tools check")
	}
	if reg.HasVisionProviderForModel(model, "ALLOWED-ONLY") {
		t.Fatal("a vision-capable but not-allowed provider must not satisfy a constrained vision check")
	}

	// Constrained to the capable provider's own serial: both checks pass again.
	if !reg.HasToolCapableProviderForModel(model, "CAPABLE-SERIAL") {
		t.Fatal("constrained to its own serial, the capable provider must satisfy the tools check")
	}
	if !reg.HasVisionProviderForModel(model, "CAPABLE-SERIAL") {
		t.Fatal("constrained to its own serial, the capable provider must satisfy the vision check")
	}
}

func TestQuickCapacityCheckForRequestRequiresVision(t *testing.T) {
	reg := New(testLogger())
	model := "vision-preflight-model"
	textOnly := makeSchedulerProvider(t, reg, "text-only", model, 100)
	textOnly.mu.Lock()
	textOnly.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: false}}
	textOnly.mu.Unlock()

	if candidates, rejections, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, true); candidates != 0 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("vision preflight with text-only provider = (%d,%d,%d), want 0/0/0", candidates, rejections, tooLarge)
	}

	vision := makeSchedulerProvider(t, reg, "vision", model, 100)
	vision.mu.Lock()
	vision.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	vision.mu.Unlock()

	if candidates, _, _ := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, true); candidates != 1 {
		t.Fatalf("vision preflight candidates=%d, want 1", candidates)
	}
}

func TestQuickCapacityCheckExcludesCriticalThermal(t *testing.T) {
	reg := New(testLogger())
	model := "critical-thermal-preflight"
	p := makeSchedulerProvider(t, reg, "hot", model, 100)
	p.mu.Lock()
	p.SystemMetrics.ThermalState = "critical"
	p.mu.Unlock()

	if candidates, rejections, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, false); candidates != 0 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("critical thermal preflight = (%d,%d,%d), want 0/0/0", candidates, rejections, tooLarge)
	}
}
