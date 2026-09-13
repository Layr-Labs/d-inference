package registry

import (
	"sync"
	"testing"
)

func TestPredictionObservationConcurrentWriterAndFinalizer(t *testing.T) {
	ap := &AttemptProfile{}
	ap.SetPredictivePolicy(false, PredictiveBypassNone)
	ap.SetReservationTTFTCeiling(0)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			ap.RecordDispatchBudget(42)
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			mode, bypass, ceiling, budget := ap.PredictionObservation()
			if mode != "soft" || bypass != PredictiveBypassNone || ceiling == nil || *ceiling != 0 {
				t.Error("policy or zero ceiling lost during snapshot")
			}
			if budget != nil {
				*budget = 999
			}
			if ceiling != nil {
				*ceiling = 999
			}
		}
	}()
	wg.Wait()
	ap.RecordDispatchBudget(100)
	_, _, ceiling, budget := ap.PredictionObservation()
	if ceiling == nil || *ceiling != 0 || budget == nil || *budget != 42 {
		t.Fatalf("snapshot or repeat write mutated first observation: ceiling=%v budget=%v", ceiling, budget)
	}
}
