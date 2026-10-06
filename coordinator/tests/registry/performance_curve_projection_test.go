package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQualifiedCurveDoesNotExtrapolate(t *testing.T) {
	reg, p, profile := reviewedServingProvider(t)
	p.Mu().Lock()
	p.DecodeTPS = 1000
	p.BackendCapacity.Slots[0].NumRunning = 7
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 1000
	p.Mu().Unlock()
	selected, decision := reg.ReserveProviderEx("model", &production.PendingRequest{RequestID: "curve-projection", Model: "model"})
	if selected != p {
		t.Fatalf("reviewed identity did not reach production routing: %+v", decision)
	}
	p.RemovePending("curve-projection")
	if got := decision.PredictedDecodeTPS; got != 35 {
		t.Fatalf("used synthetic curve instead of measured conservative point: %v", got)
	}
	if _, ok := profile.BatchAt(17); ok {
		t.Fatal("extrapolated beyond measured width")
	}
	profile.BatchCurve[1].DecodeP10TPS = 29
	if profile.Valid() {
		t.Fatal("accepted sub-floor release curve")
	}
}
