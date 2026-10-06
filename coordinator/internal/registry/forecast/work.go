package forecast

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// PendingWork retains bounded service inputs, not the request or its output
// reservation. The caller freezes them under the provider's critical section.
type PendingWork struct {
	Model                                           string
	ReservedAt                                      time.Time
	RequestedMaxTokens, EstimatedPromptTokens       int
	ContentCommitted, ReservedPrefillKnown          bool
	ReservedPrefillTokens, ReservedPrefillRestoreMS float64
}

func PendingServiceMS(pending PendingWork, decode, prefill float64) float64 {
	output := memorypolicy.DefaultRequestedMaxTokens
	if pending.RequestedMaxTokens > 0 {
		output = min(output, pending.RequestedMaxTokens)
	}
	work := float64(output) / decode * 1000
	if !pending.ContentCommitted {
		prompt := float64(max(0, pending.EstimatedPromptTokens))
		if pending.ReservedPrefillKnown {
			prompt = pending.ReservedPrefillTokens
		}
		work += prompt/prefill*1000 + pending.ReservedPrefillRestoreMS
	}
	return work
}

// WorkBuilder reconciles reported and locally reserved bounded service. The
// caller holds the provider lock across construction, Pending and Finish.
type WorkBuilder struct {
	model                                                string
	capacity                                             *protocol.BackendCapacity
	acceptedAt                                           time.Time
	decode, prefill                                      float64
	work                                                 Workload
	slotModel                                            string
	slotDecode, slotPrefill, reported, local, unreported float64
	reportedCount, localCount, unreportedCount           int
}

func NewWorkBuilder(model string, capacity *protocol.BackendCapacity, acceptedAt time.Time, decode, prefill float64, occupied bool) WorkBuilder {
	return WorkBuilder{model: model, capacity: capacity, acceptedAt: acceptedAt, decode: decode, prefill: prefill,
		work: Workload{WholeMacBusy: occupied, WholeMacKnown: capacity != nil && len(capacity.Slots) > 0}}
}

// BeginSlot starts reported/local overlap accounting for one producer slot.
func (b *WorkBuilder) BeginSlot(i int) {
	slot := &b.capacity.Slots[i]
	t := slot.Telemetry
	known := t != nil && t.QueuedPrefillTokens != nil && t.PartialPrefillRows != nil
	busy := slot.NumRunning > 0 || slot.NumWaiting > 0 || slot.EvalInFlightMs > 0 || slot.IdleClearInFlightMs > 0 || slot.WedgeSuspected
	if t != nil {
		busy = busy || (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > 0) || (t.PartialPrefillRows != nil && *t.PartialPrefillRows > 0)
	}
	dormant := slot.Model != b.model && slot.State == "idle_shutdown" && !busy
	if !dormant {
		b.work.WholeMacKnown = b.work.WholeMacKnown && known
		b.work.WholeMacBusy = b.work.WholeMacBusy || busy || (slot.State != "running" && slot.State != "idle")
	}
	decode, prefill := b.decode, b.prefill
	if slot.ObservedDecodeTPS > 0 {
		decode = slot.ObservedDecodeTPS
	}
	if slot.ObservedPrefillTPS > 0 {
		prefill = slot.ObservedPrefillTPS
	}
	decode, prefill = max(1, decode), max(1, prefill)
	reported := float64(max(0, slot.NumRunning)+max(0, slot.NumWaiting)) * memorypolicy.DefaultRequestedMaxTokens / decode * 1000
	if t != nil && t.QueuedPrefillTokens != nil {
		reported += float64(max(0, *t.QueuedPrefillTokens)) / prefill * 1000
	}
	b.slotModel, b.slotDecode, b.slotPrefill = slot.Model, decode, prefill
	b.reported, b.reportedCount = reported, int(max(0, slot.NumRunning)+max(0, slot.NumWaiting))
	b.local, b.unreported, b.localCount, b.unreportedCount = 0, 0, 0, 0
}

func (b *WorkBuilder) Pending(pending PendingWork) {
	if pending.Model == b.slotModel {
		service := PendingServiceMS(pending, b.slotDecode, b.slotPrefill)
		if !b.acceptedAt.IsZero() && !pending.ReservedAt.Before(b.acceptedAt) {
			b.unreported += service
			b.unreportedCount++
		} else {
			b.local += service
			b.localCount++
		}
	}
}

func (b *WorkBuilder) EndSlot() {
	if b.slotModel != b.model {
		b.work.OtherModelOccupancy += max(b.localCount, b.reportedCount) + b.unreportedCount
	}
	b.work.ServiceMS += max(b.reported, b.local) + b.unreported
}

// UnreportedPending accounts for cold models absent from producer slots and
// marks all local reservations busy even before the producer reflects them.
func (b *WorkBuilder) UnreportedPending(pending PendingWork) {
	present := false
	for i := range b.capacity.Slots {
		if b.capacity.Slots[i].Model == pending.Model {
			present = true
			break
		}
	}
	if !present {
		b.work.ServiceMS += PendingServiceMS(pending, max(1, b.decode), max(1, b.prefill))
		if pending.Model != b.model {
			b.work.OtherModelOccupancy++
		}
	}
	b.work.WholeMacBusy = true
}

func (b *WorkBuilder) Finish() Workload { return b.work }
