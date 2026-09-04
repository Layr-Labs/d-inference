package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// noteDeadlineWedgeRefusal feeds one pre-content deadline_unreachable refusal
// into the registry's deadline-wedge tracker (registry/deadline_wedge.go).
// It is the single hook on the dispatch loop's error funnel
// (noteDispatchRetry), which receives the exact provider and pending request
// of the failed attempt before the loop clears them. Speculative backups are
// excluded: their remaining budget is shrunken by construction, so their
// refusals say nothing about the slot. Other reasons are ignored here; the
// health-neutral treatment of deadline refusals elsewhere is unchanged (the
// tracker is the only consumer). Emits routing.deadline_wedge_skip{model,
// event} so the shadow census is visible before the switch is flipped.
func (d *dispatchState) noteDeadlineWedgeRefusal(provider *registry.Provider, pr *registry.PendingRequest, errReason string) {
	if provider == nil || pr == nil || !isDeadlineUnreachableErrorReason(errReason) {
		return
	}
	if pr.Profile != nil && pr.Profile.BackupOf != "" {
		return
	}
	event := d.s.registry.NoteDeadlineRefusal(provider.ID, pr.Model, pr.EstimatedPromptTokens, pr.ReserveOccupancy)
	d.s.ddIncr("routing.deadline_wedge_skip", []string{"model:" + pr.Model, "event:" + string(event)})
}
