package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
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
//
// The registry applies the slot discriminators (registry.
// deadlineRefusalIndictsSlot: short prompt, empty slot, primary attempt, a
// first-content clock the coordinator had barely consumed at dispatch), so
// retry cascades and budget eaten coordinator-side never count.
//
// Only a PROVIDER-originated refusal counts. The coordinator synthesizes the
// same deadline_unreachable capacity 503 itself when an ADMITTED attempt's
// first content (or clean empty completion) lands after the request-absolute
// deadline (api/provider.go, stamped CoordinatorCauseDeadlineLateContent):
// there the engine accepted and worked the request, so the terminal indicts
// the clock — a coordinator lock-wait or queue episode — not the slot.
// Counting those would arm healthy idle pairs during exactly the saturation
// the wedge skip must not amplify, and would inflate the shadow census
// (armed_pairs) the flip decision reads.
func (d *dispatchState) noteDeadlineWedgeRefusal(provider *registry.Provider, pr *registry.PendingRequest, errReason string, coordinatorCause protocol.CoordinatorInferenceErrorCause) {
	if provider == nil || pr == nil || !isDeadlineUnreachableErrorReason(errReason) {
		return
	}
	if coordinatorCause != "" {
		return
	}
	if pr.Profile != nil && pr.Profile.BackupOf != "" {
		return
	}
	event := d.s.registry.NoteDeadlineRefusal(provider.ID, pr)
	d.s.ddIncr("routing.deadline_wedge_skip", []string{"model:" + pr.Model, "event:" + string(event)})
}
