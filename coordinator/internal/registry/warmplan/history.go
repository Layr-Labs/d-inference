package warmplan

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type workCounters struct {
	epoch                                 string
	prompt, prefills, output, generations int64
	lastWorkAt                            time.Time
	observedAt                            time.Time
}

// WorkHistory owns slot-lifetime baselines. Its provider owner serializes these
// operations with capacity acceptance, so stale sequence numbers never enter it.
type WorkHistory struct{ models map[string]workCounters }

func (h *WorkHistory) Reset() {
	if h != nil {
		h.models = nil
	}
}

func (h *WorkHistory) Count() int {
	if h == nil {
		return 0
	}
	return len(h.models)
}

func (h *WorkHistory) Prune(eligible map[string]bool) {
	if h == nil {
		return
	}
	for model := range h.models {
		if !eligible[model] {
			delete(h.models, model)
		}
	}
}

func (h *WorkHistory) RecentOther(model string, now time.Time, dwell time.Duration) int {
	if h == nil {
		return 0
	}
	count := 0
	for resident, work := range h.models {
		if resident != model && !work.lastWorkAt.IsZero() && now.Sub(work.lastWorkAt) < dwell {
			count++
		}
	}
	return count
}

func (h *WorkHistory) Reconcile(capacity *protocol.BackendCapacity, now time.Time, state *State, eligible map[string]bool, freshness time.Duration) {
	if capacity == nil || state == nil || len(eligible) == 0 {
		h.Reset()
		return
	}
	next := make(map[string]workCounters, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		t := slot.Telemetry
		if !eligible[slot.Model] || (slot.State != "idle" && slot.State != "running") || t == nil || slot.PerformanceMeasurements == nil || slot.PerformanceMeasurements.Epoch == "" ||
			t.PrefillTokensTotal == nil || t.PrefillRequestsTotal == nil ||
			t.GeneratedTokensTotal == nil || t.GenerationRequestsTotal == nil {
			continue
		}
		v := workCounters{epoch: slot.PerformanceMeasurements.Epoch, prompt: *t.PrefillTokensTotal, prefills: *t.PrefillRequestsTotal, output: *t.GeneratedTokensTotal, generations: *t.GenerationRequestsTotal, observedAt: now}
		if v.prompt < 0 || v.prefills < 0 || v.output < 0 || v.generations < 0 {
			continue
		}
		next[slot.Model] = v
		old, ok := h.models[slot.Model]
		if !ok || old.epoch != v.epoch || now.Before(old.observedAt) || now.Sub(old.observedAt) > freshness || v.prompt < old.prompt || v.prefills < old.prefills || v.output < old.output || v.generations < old.generations {
			continue
		}
		v.lastWorkAt = old.lastWorkAt
		if v.prefills > old.prefills || v.generations > old.generations {
			v.lastWorkAt = now
		}
		next[slot.Model] = v
		state.RecordWork(slot.Model, v.prompt-old.prompt, v.prefills-old.prefills, v.output-old.output, v.generations-old.generations, now)
	}
	h.models = next
}
