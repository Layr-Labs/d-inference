package deadline

import (
	"math"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// WorkBuilder joins validated producer envelopes with frozen local owners. Its
// caller holds the same provider critical section throughout the assembly.
type WorkBuilder struct {
	model       string
	identity    Identity
	catalog     *Catalog
	work        firstcontent.Work
	competitors map[string]bool
}

// BoundSlots cannot infer a missing local workload from heartbeat receipt time.
func BoundSlots(catalog *Catalog, identity Identity, model string) (WorkBuilder, bool) {
	capacity := identity.Capacity
	if capacity == nil || capacity.WholeMacServiceUsed == nil || !capacityvalue.ValidWholeMacServiceReservations(capacity) ||
		(capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive) {
		return WorkBuilder{}, false
	}
	reported := *capacity.WholeMacServiceUsed
	if !FiniteServiceFraction(reported) {
		return WorkBuilder{}, false
	}
	b := WorkBuilder{model: model, identity: identity, catalog: catalog, competitors: make(map[string]bool)}
	service, targetFound, evaluating := 0.0, false, false
	for _, slot := range capacity.Slots {
		w := slot.DeadlineWork
		busy := slot.NumRunning > 0 || slot.NumWaiting > 0 || slot.EvalInFlightMs > 0 || slot.IdleClearInFlightMs > 0 || slot.WedgeSuspected ||
			(w != nil && (w.RequestCount > 0 || w.ServiceFraction > 0))
		if t := slot.Telemetry; t != nil {
			busy = busy || (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > 0) || (t.PartialPrefillRows != nil && *t.PartialPrefillRows > 0)
		}
		if slot.Model != model && !busy {
			continue
		}
		if !ValidWork(w, slot.PerformanceMeasurements) || (slot.State != "running" && slot.State != "idle") || slot.WedgeSuspected || slot.IdleClearInFlightMs > 0 {
			return WorkBuilder{}, false
		}
		if w.RequestCount < slot.NumRunning+slot.NumWaiting {
			return WorkBuilder{}, false
		}
		if t := slot.Telemetry; t != nil {
			if (t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens > w.PrefillTokens) ||
				(t.PartialPrefillRows != nil && *t.PartialPrefillRows > int64(w.RequestCount)) {
				return WorkBuilder{}, false
			}
		}
		evaluating = evaluating || slot.EvalInFlightMs > 0
		profile := catalog.Qualified(identity, slot.Model)
		if profile == nil || w.ContextTokensMax > profile.MeasuredContextTokensMax() {
			return WorkBuilder{}, false
		}
		b.work.PrefillTokens += float64(w.PrefillTokens)
		b.work.DecodeTokens += float64(w.DecodeTokens)
		b.work.ActiveRequests += w.RequestCount
		service += w.ServiceFraction
		if slot.Model == model {
			targetFound = true
			b.work.ContextTokens = max(b.work.ContextTokens, w.ContextTokensMax)
		} else {
			b.work.OtherModelRequests += w.RequestCount
			b.work.OtherModelServiceFraction += w.ServiceFraction
			b.competitors[profile.ID] = true
		}
	}
	if !targetFound || math.Abs(service-reported) > 1e-9 || (evaluating && b.work.ActiveRequests == 0) {
		return WorkBuilder{}, false
	}
	return b, true
}

// Retiring requires the producer to still account for the exact frozen owner.
func (b *WorkBuilder) Retiring(charge, reportedCharge float64) bool {
	return reportedCharge+1e-12 >= charge
}

type PendingWork struct {
	Model              string
	PromptWork         *protocol.PromptWork
	RequestedMaxTokens int
	ServiceCharge      float64
}

func (b *WorkBuilder) Pending(pending PendingWork, reportedCharge float64) bool {
	if reportedCharge > 0 {
		return reportedCharge+1e-12 >= pending.ServiceCharge
	}
	profile := b.catalog.Qualified(b.identity, pending.Model)
	if profile == nil || profile.DeadlineCalibration == nil ||
		!pending.PromptWork.IsQualifiedFor(profile.ArtifactSHA256, profile.DeadlineCalibration.PromptContractID) ||
		pending.RequestedMaxTokens <= 0 || pending.RequestedMaxTokens > profile.MeasuredContextTokensMax() ||
		pending.PromptWork.UpperBoundTokens > profile.MeasuredContextTokensMax()-pending.RequestedMaxTokens ||
		!FiniteServiceFraction(pending.ServiceCharge) || pending.ServiceCharge == 0 {
		return false
	}
	b.work.PrefillTokens += float64(pending.PromptWork.UpperBoundTokens)
	b.work.DecodeTokens += float64(pending.RequestedMaxTokens)
	b.work.ActiveRequests++
	if pending.Model == b.model {
		b.work.ContextTokens = max(b.work.ContextTokens, pending.PromptWork.UpperBoundTokens+pending.RequestedMaxTokens)
	} else {
		b.work.OtherModelRequests++
		b.work.OtherModelServiceFraction += pending.ServiceCharge
		b.competitors[profile.ID] = true
	}
	return true
}

func (b *WorkBuilder) Finish() firstcontent.Work {
	for id := range b.competitors {
		b.work.CompetitorProfileIDs = append(b.work.CompetitorProfileIDs, id)
	}
	sort.Strings(b.work.CompetitorProfileIDs)
	return b.work
}

func FiniteServiceFraction(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 && v <= 1+1e-12
}

func ValidWork(w *protocol.DeadlineWork, measurements *protocol.PerformanceMeasurements) bool {
	if w == nil || w.Version != 1 || !w.Known || measurements == nil || w.Epoch == "" || w.Epoch != measurements.Epoch ||
		len(w.Epoch) > 64 || w.PrefillTokens < 0 || w.DecodeTokens < 0 || w.PrefillTokens > 1<<30 || w.DecodeTokens > 1<<30 ||
		w.RequestCount < 0 || w.RequestCount > 64 || w.ContextTokensMax < 0 || w.ContextTokensMax > 1<<20 || !FiniteServiceFraction(w.ServiceFraction) {
		return false
	}
	if w.RequestCount == 0 {
		return w.PrefillTokens == 0 && w.DecodeTokens == 0 && w.ContextTokensMax == 0 && w.ServiceFraction == 0
	}
	// A nonempty owner retains its full original positive prompt, even after reuse.
	if w.PrefillTokens < int64(w.RequestCount) || w.ContextTokensMax <= 0 || w.ServiceFraction <= 0 {
		return false
	}
	total, context, count := w.PrefillTokens+w.DecodeTokens, int64(w.ContextTokensMax), int64(w.RequestCount)
	return context <= total-(count-1) && total <= count*context
}
