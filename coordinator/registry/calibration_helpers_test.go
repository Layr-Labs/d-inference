package registry

import (
	"fmt"
	"testing"
)

func resetCalibrator(t *testing.T) {
	t.Helper()
	ResetTTFTCalibration()
	t.Cleanup(ResetTTFTCalibration)
}

// feedObservations pushes n prediction+actual pairs for (model, chip) with the
// given actual/predicted ratio through the real join path.
func feedObservations(t *testing.T, model, chip string, n int, ratio float64) {
	t.Helper()
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s-%s-obs-%d", model, chip, i)
		routingPolicy.NotePrediction(id, 0, model, chip, 1000)
		if _, ok := routingPolicy.RecordTTFTObservation(id, 0, 1000*ratio); !ok {
			t.Fatalf("observation %d not recorded", i)
		}
	}
}
