package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"time"
)

func publicAutopilotPending(p *PendingRequest) bool {
	if p == nil || p.SelfRouteOnly || p.PreferOwner || len(p.AllowedProviderSerials) > 0 || len(p.ExcludedProviderIDs) > 0 {
		return false
	}
	profile := p.Profile
	if profile != nil && profile.ProviderCompleteObserved.Load() {
		return false
	}
	parent := profile.Parent()
	return parent == nil || (parent.ClientGoneUS.Load() == 0 && parent.DoneFlushedUS.Load() == 0)
}

// Registry membership is locked by the caller; copy immutable request fields
// under each provider lock. Opaque IDs exist only for transient queue/active
// deduplication and never enter the policy package, logs or demand history.
func (r *Registry) autopilotActiveSamplesLocked() ([]autopilot.DemandSample, map[string]bool, map[string]bool) {
	var samples []autopilot.DemandSample
	ids, unscoped := map[string]bool{}, map[string]bool{}
	for _, p := range r.providers {
		p.mu.Lock()
		accepted := map[string]int{}
		acceptedLeases := map[string]bool{}
		if !p.PrivateOnly {
			for id, request := range p.pendingReqs {
				if !publicAutopilotPending(request) {
					continue
				}
				profile := request.Profile
				parent := profile.Parent()
				// Enabled Autopilot observations create compact profiles even
				// with heavy profiling off. Incomplete provenance stays unscoped.
				if parent == nil || parent.T0.IsZero() || parent.HandlerEntryUS.Load() <= 0 {
					continue
				}
				sample := autopilot.DemandSample{Model: request.Model, PromptTokens: request.EstimatedPromptTokens,
					RequestedMaxTokens: request.RequestedMaxTokens,
					Requirements:       request.Traits.AutopilotRequirements(request.RequiresVision), DeadlineKnown: true}
				if parent != nil && parent.HandlerEntryUS.Load() > 0 {
					sample.ReceivedAt = parent.T0.Add(time.Duration(parent.HandlerEntryUS.Load()) * time.Microsecond)
				}
				if !request.FirstContentDeadline.IsZero() {
					// The request-start stamp is immutable; never read mutable
					// attempt budgets or dispatch-owned timing fields here.
					if sample.ReceivedAt.IsZero() {
						continue
					}
					sample.FirstContentDeadline = request.FirstContentDeadline.Sub(sample.ReceivedAt)
				}
				if !sample.ValidEnvelope() || sample.FirstContentDeadline < 0 {
					continue
				}
				samples = append(samples, sample)
				ids[id] = true
				if profile != nil && profile.AcceptedUS.Load() > 0 {
					accepted[request.Model]++
					acceptedLeases[request.ServiceReservationID()] = true
				}
			}
		}
		if p.BackendCapacity != nil {
			capacity := p.BackendCapacity
			// Consumer completion is not engine retirement. Current-master service
			// claims and loading/maintenance work must retain their Mac-wide debit.
			if len(p.serviceRetirementShadows) > 0 || (capacity.LoadTransitionActive != nil && *capacity.LoadTransitionActive) {
				unscoped[p.ID] = true
			}
			publicCharge := 0.0
			for _, lease := range capacity.WholeMacServiceReservations {
				if lease.ID == "" || !acceptedLeases[lease.ID] {
					unscoped[p.ID] = true
				} else {
					publicCharge += lease.UsedFraction
				}
			}
			if used := capacity.WholeMacServiceUsed; used != nil && (!validWholeMacServiceReservations(capacity) || !finiteServiceFraction(*used) || *used > publicCharge+1e-12) {
				unscoped[p.ID] = true
			}
			for _, slot := range p.BackendCapacity.Slots {
				unattributedWork := false
				if accepted[slot.Model] == 0 {
					unattributedWork = slot.ActiveTokens != 0 || slot.ActiveTokenBudgetUsed != 0 || slot.QueuedTokenBudget != 0 ||
						slot.EvalInFlightMs != 0 || slot.IdleClearInFlightMs != 0 || slot.WedgeSuspected
					if telemetry := slot.Telemetry; telemetry != nil {
						unattributedWork = unattributedWork || (telemetry.QueuedPrefillTokens != nil && *telemetry.QueuedPrefillTokens != 0) ||
							(telemetry.PartialPrefillRows != nil && *telemetry.PartialPrefillRows != 0) ||
							(telemetry.EvalInFlightMS != nil && *telemetry.EvalInFlightMS != 0)
					}
				}
				if max(0, slot.NumRunning)+max(0, slot.NumWaiting) > accepted[slot.Model] || unattributedWork ||
					(slot.DeadlineWork != nil && (!slot.DeadlineWork.Known || slot.DeadlineWork.RequestCount > accepted[slot.Model])) {
					// Unattributed/local/private work retains its GPU claim but
					// creates neither public demand nor spare public capacity.
					unscoped[p.ID] = true
					break
				}
			}
		}
		p.mu.Unlock()
	}
	return samples, ids, unscoped
}
