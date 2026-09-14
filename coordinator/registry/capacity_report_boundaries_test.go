package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"math"
	"testing"
)

func TestClampBackendCapacityIntegerBoundaries(t *testing.T) {
	for _, reported := range []int64{-1, 0, 7, math.MaxInt64} {
		bc := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
			MaxTokensPotential: reported, MaxConcurrency: int(reported),
			NumRunning: int(reported), NumWaiting: int(reported),
			ModelLoadTimeMS: reported, ActiveTokenBudgetUsed: reported,
			ActiveTokenBudgetMax: reported, QueuedTokenBudget: reported,
		}}}
		clampBackendCapacity(testLogger(), "boundaries", bc)
		s := bc.Slots[0]
		for name, value := range map[string]struct{ got, limit int64 }{
			"tokens":      {int64(s.MaxTokensPotential), maxTokensPotential},
			"concurrency": {int64(s.MaxConcurrency), maxReportedMaxConcurrency},
			"running":     {int64(s.NumRunning), math.MaxInt64},
			"waiting":     {int64(s.NumWaiting), math.MaxInt64},
			"load":        {s.ModelLoadTimeMS, maxModelLoadTimeMS},
			"used":        {s.ActiveTokenBudgetUsed, maxTokenBudgetCap},
			"maximum":     {s.ActiveTokenBudgetMax, maxTokenBudgetCap},
			"queued":      {s.QueuedTokenBudget, maxTokenBudgetCap},
		} {
			want := reported
			if want < 0 {
				want = 0
			}
			if want > value.limit {
				want = value.limit
			}
			if value.got != want {
				t.Errorf("%s report %d: got %d, want %d", name, reported, value.got, want)
			}
		}
	}
}
