package registry

import (
	"fmt"
	"math"
	"testing"
)

// Calibration observations and startup tuning have process lifetime. Distinct
// registries must read the same state through real preflight and reserve paths.
func TestRoutingPolicySharedAcrossRegistryBindings(t *testing.T) {
	resetCalibrator(t)
	originalRatio := PrefillToDecodeRatio()
	t.Cleanup(func() { SetPrefillToDecodeRatio(originalRatio) })
	first, second := New(testLogger()), New(testLogger())
	const model = "shared-routing-policy-model"
	calibrationTestProvider(t, first, "first-box", model, 100, 1000)
	calibrationTestProvider(t, second, "second-box", model, 100, 1000)
	request := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, MaxTTFTMs: 750}
	}
	if p, d := second.ReserveProviderEx(model, request("before")); p != nil || d.TTFTRejections != 1 || math.Abs(d.BestTTFTMs-1010) > 0.001 {
		t.Fatalf("uncalibrated second registry: selected=%v decision=%+v", p != nil, d)
	}
	for i := 0; i < 60; i++ {
		pr := request(fmt.Sprintf("shared-observation-%d", i))
		pr.MaxTTFTMs = 0
		p, d := first.ReserveProviderEx(model, pr)
		if p == nil {
			t.Fatalf("first registry reserve %d: %+v", i, d)
		}
		if _, ok := RecordTTFTObservation(pr.RequestID, pr.Attempt, 404); !ok {
			t.Fatalf("first registry observation %d was not joined", i)
		}
		p.RemovePending(pr.RequestID)
		first.SetProviderIdle(p.ID)
	}
	check := func(reg *Registry, id string) {
		t.Helper()
		_, _, _, estimate, known := reg.QuickCapacityCheckWithTTFTForRequest(model, 1000, 128, RequestTraits{}, false)
		if !known || math.Abs(float64(estimate.Microseconds())/1000-404) > 0.001 {
			t.Fatalf("shared preflight estimate=%v known=%v", estimate, known)
		}
		pr := request(id)
		p, d := reg.ReserveProviderEx(model, pr)
		if p == nil || math.Abs(d.TTFTMs-404) > 0.001 || math.Abs(d.TTFTCalibrationRatio-0.4) > 0.001 {
			t.Fatalf("shared reserve selected=%v decision=%+v", p != nil, d)
		}
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	check(second, "after")
	third := New(testLogger())
	calibrationTestProvider(t, third, "third-box", model, 100, 1000)
	check(third, "after-new-registry")

	// Configure after constructing registries, before any serving goroutine, as
	// startup composition does. Both snapshots must read the effective override.
	SetPrefillToDecodeRatio(20)
	for i, reg := range []*Registry{first, second} {
		const fallbackModel = "shared-prefill-fallback"
		calibrationTestProvider(t, reg, fmt.Sprintf("fallback-%d", i), fallbackModel, 100, 0)
		pr := &PendingRequest{RequestID: fmt.Sprintf("fallback-request-%d", i), Model: fallbackModel, EstimatedPromptTokens: 1000, RequestedMaxTokens: 128}
		p, d := reg.ReserveProviderEx(fallbackModel, pr)
		if p == nil || d.PrefillDecodeRatio != 20 || math.Abs(d.RawTTFTMs-510) > 0.001 {
			t.Fatalf("startup ratio registry=%d selected=%v decision=%+v", i, p != nil, d)
		}
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
}
