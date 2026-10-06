package inference

import (
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// noteProviderDispatched counts one inference frame actually handed to a
// provider. It is invoked only after the writer confirms final authorization
// and socket handoff, for primary, queued, plan-retry and speculative-backup
// sends alike. The request owner publishes it before any subsequent outcome or
// exhaustion accounting; merely preparing a frame does not count as dispatch.
func (d *dispatchState) noteProviderDispatched() {
	d.accounting().Commit()
}

func (d *dispatchState) accounting() *providerwire.Accounting {
	if d.sendAccounting == nil {
		d.sendAccounting = &providerwire.Accounting{}
	}
	return d.sendAccounting
}

// exhaustionAttemptCount is the machine count client-visible exhaustion
// messages and terminal logs report: actual provider dispatches when any
// frame reached a provider (plan Phase 3: "providerDispatches counts actual
// inference sends"), else the legacy loop count for requests that never
// dispatched (selection/preparation-only failures, including authorization
// rejection, retain their historical "after N attempt(s)" framing). This
// fallback is an attempted-loop count, not a claim of provider delivery. Route
// rows keep the raw loop index unchanged.
func (d *dispatchState) exhaustionAttemptCount(lastAttempt int) int {
	return d.accounting().ExhaustionCount(lastAttempt)
}

func (d *dispatchState) dispatchPlan() *providerdispatch.Plan {
	if d.retainedPlan == nil {
		d.retainedPlan = d.s.NewDispatcher().NewPlan(nil)
	}
	return d.retainedPlan
}

func (d *dispatchState) dispatchInput(timing *registry.RequestTiming, exclude map[string]struct{}, backupOf string, recordRoute routeDecisionRecorder) providerdispatch.Input {
	return providerdispatch.Input{
		Request: d.r, Model: d.model, PublicModel: d.publicModel, Body: d.rawBody, Stream: d.stream,
		ConsumerKey: d.consumerKey, ConsumerLocation: d.consumerLocation,
		ReservedMicroUSD: d.reservedMicroUSD, EstimatedPromptTokens: d.estimatedPromptTokens,
		Deadline: d.deadline, RequestedMaxTokens: d.requestedMaxTokens, TokenAdmission: d.tokenAdmission,
		RequiresVision: d.requiresVision, Traits: d.traits(), AllowedProviderSerials: d.allowedProviderSerials,
		IsResponsesAPI: d.isResponsesAPI,
		Scope:          providerdispatch.Scope{SelfRouteOnly: d.policy.enabled, PreferOwner: d.policy.prefer, OwnerAccountID: d.policy.ownerAccountID},
		Timing:         timing, ServiceReservation: d.serviceReservation, CachePlan: d.cachePlan,
		Exclusions: dispatchExclusions(exclude), Attempt: d.attempt, Profile: d.profile, BackupOf: backupOf,
		RecordRoute: recordRoute, OnDispatched: d.noteProviderDispatched, Forecast: d.requestForecast(),
	}
}
