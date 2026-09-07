package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func executionProvider(t *testing.T, r *Registry, model string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, "execution-provider", model, 400)
	p.mu.Lock()
	p.PrefillTPS = 5000
	p.Models[0].ExecutionIdentity = executionK4
	p.BackendCapacity.Slots[0].ExecutionIdentity = executionK4
	p.BackendCapacity.Slots[0].MaxConcurrency = 4
	p.mu.Unlock()
	return p
}

func TestExecutionBootstrapFourKHasUnknownTTFTAndStillAdmitsOne(t *testing.T) {
	resetCalibrator(t)
	r := New(testLogger())
	p := executionProvider(t, r, "execution-bootstrap")
	r.tpsRegistry.Record("execution-bootstrap", p.Hardware.ChipFamily, 400) // unrelated native history
	count, _, _, ttft, known := r.QuickCapacityCheckWithTTFTForRequest("execution-bootstrap", 4096, 64, RequestTraits{}, false)
	if count != 1 || known || ttft != 0 {
		t.Fatalf("bootstrap preflight count=%d ttft=%v known=%v", count, ttft, known)
	}
	req := &PendingRequest{RequestID: "first-quant", Model: "execution-bootstrap", EstimatedPromptTokens: 4096, RequestedMaxTokens: 64, MaxTTFTMs: 120000}
	selected, decision := r.ReserveProviderEx(req.Model, req)
	if selected == nil {
		t.Fatalf("first measurement deadlocked: %+v", decision)
	}
	if _, learned := RecordTTFTObservation(req.RequestID, req.Attempt, 30000); learned {
		t.Fatal("unknown forecast trained calibration")
	}
	second := &PendingRequest{RequestID: "second-quant", Model: req.Model, EstimatedPromptTokens: 4096, RequestedMaxTokens: 64, MaxTTFTMs: 120000}
	if selected, _ := r.ReserveProviderEx(req.Model, second); selected != nil {
		t.Fatal("uncalibrated execution exceeded concurrency1")
	}
	p.RemovePending(req.RequestID)
	r.SetProviderIdle(p.ID)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 256
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 20
	p.mu.Unlock()
	count, _, _, ttft, known = r.QuickCapacityCheckWithTTFTForRequest(req.Model, 4096, 64, RequestTraits{}, false)
	if count != 1 || !known || ttft < 16*time.Second {
		t.Fatalf("observed execution failed to calibrate: count=%d time=%v known=%v", count, ttft, known)
	}
}

func TestExecutionColdDeclarationPreservesLoadBiasAndBootstrap(t *testing.T) {
	r := New(testLogger())
	p := executionProvider(t, r, "execution-cold")
	p.mu.Lock()
	p.BackendCapacity.Slots = nil
	p.mu.Unlock()
	count, _, _, _, known := r.QuickCapacityCheckWithTTFTForRequest("execution-cold", 4096, 64, RequestTraits{}, false)
	if count != 1 || known {
		t.Fatalf("cold uncalibrated preflight count=%d known=%v", count, known)
	}
	tight := &PendingRequest{RequestID: "cold-quant-tight", Model: "execution-cold", EstimatedPromptTokens: 4096, RequestedMaxTokens: 64, MaxTTFTMs: 5000}
	if selected, _ := r.ReserveProviderEx(tight.Model, tight); selected != nil {
		t.Fatal("unknown compute erased the independent cold-load deadline lower bound")
	}
	req := &PendingRequest{RequestID: "cold-quant", Model: "execution-cold", EstimatedPromptTokens: 4096, RequestedMaxTokens: 64, MaxTTFTMs: 120000}
	selected, decision := r.ReserveProviderEx(req.Model, req)
	if selected == nil || decision.StateMs <= 0 {
		t.Fatalf("cold dispatch/loss of load bias: %+v", decision)
	}
}

func TestExecutionConcurrencyRequiresQualifiedSameIdentitySoloSamples(t *testing.T) {
	r := New(testLogger())
	p := executionProvider(t, r, "execution-solo")
	enablePerModelQualityCap(t, r, "execution-solo=400", "", "5")
	threshold := max(1, qualityCapSoloMinSamples)
	for i := 0; i < threshold; i++ {
		r.tpsRegistry.RecordSolo("execution-solo", chipClassKey(p.Hardware), 400)
	}
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 400 // a single point estimate is not qualified
	if got := r.effectiveMaxConcurrencyForModelResolvedLocked(p, "execution-solo"); got != 1 {
		t.Fatalf("native/own seed borrowed: cap=%d", got)
	}
	p.mu.Unlock()
	for i := 0; i < threshold; i++ {
		r.tpsRegistry.RecordSolo("execution-solo", chipClassKey(p.Hardware), 80, executionK4)
		p.mu.Lock()
		got := r.effectiveMaxConcurrencyForModelResolvedLocked(p, "execution-solo")
		p.mu.Unlock()
		if i+1 < threshold && got != 1 {
			t.Fatalf("unqualified %d samples expanded cap=%d", i+1, got)
		}
		if i+1 == threshold && (got <= 1 || got > 4) {
			t.Fatalf("qualified samples did not respect configured bound: %d", got)
		}
	}
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ExecutionIdentity = executionK8V4
	if got := r.effectiveMaxConcurrencyForModelResolvedLocked(p, "execution-solo"); got != 1 {
		t.Fatalf("K4 rates leaked to K8V4: %d", got)
	}
	p.BackendCapacity.Slots[0] = protocol.BackendSlotCapacity{Model: "execution-solo", State: "idle", MaxConcurrency: 4}
	if providerExecutionIdentityLocked(p, "execution-solo") != "" {
		t.Fatal("actual native replacement did not override declaration")
	}
	p.mu.Unlock()
}

func TestExecutionPlaceholderCannotLendStaleObservedRates(t *testing.T) {
	r := New(testLogger())
	p := executionProvider(t, r, "execution-stale")
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, state := range []string{"reloading", "loading", "idle_shutdown", "crashed", "unknown"} {
		p.BackendCapacity.Slots[0].State = state
		p.BackendCapacity.Slots[0].ExecutionIdentity = ""
		p.BackendCapacity.Slots[0].ObservedDecodeTPS = 400
		p.BackendCapacity.Slots[0].ObservedPrefillTPS = 5000
		decode, prefill := resolvedModelTPSLocked(p, "execution-stale")
		if decode != 0 || prefill != 0 {
			t.Fatalf("%s lent stale rates %v/%v", state, decode, prefill)
		}
		snap := routingSnapshot{slotState: state, observedDecodeTPS: 400, observedPrefillTPS: 5000}
		applyExecutionPerformanceSnapshot(&snap, p, "execution-stale")
		if snap.observedDecodeTPS != 0 || !executionPrefillUncalibrated(&snap) {
			t.Fatalf("%s snapshot borrowed rates", state)
		}
	}
}

func TestExecutionModelsUpdateRetainsOnlyNormalizedIdentity(t *testing.T) {
	r := New(testLogger())
	p := executionProvider(t, r, "execution-update")
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{{ID: "execution-update", ExecutionIdentity: "unexpected-format"}})
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.Models[0].ExecutionIdentity != invalidExecutionIdentity {
		t.Fatalf("unbounded ingress value retained: %q", p.Models[0].ExecutionIdentity)
	}
}
