package inference

import (
	"encoding/json"
	"net/http"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// writeTimingHeaderWithProfile is writeTimingHeader plus the profiler's
// additive keys: the legacy keys keep their documented formulas (clamped at
// zero with timing_anomaly set when a retried attempt made one negative), the
// additive keys are derived from the attempt stamps. With the profiler off
// the header is byte-for-byte the legacy output.
func (d *dispatchState) writeTimingHeaderWithProfile(w http.ResponseWriter, pr *registry.PendingRequest) {
	tj := inresp.RequestTimingDetails(pr.Timing)
	if tj == nil {
		return
	}
	d.applyProfileTiming(tj, pr)
	if tjJSON, err := json.Marshal(tj); err == nil {
		w.Header().Set("X-Timing", string(tjJSON))
	}
}

func (d *dispatchState) applyProfileTiming(tj *types.RequestTimingDetails, pr *registry.PendingRequest) {
	observation.ApplyProfileTiming(d.profile, tj, pr)
}

// stampFirstContent records the first-content stamps on the committed attempt.
func (d *dispatchState) stampFirstContent(pr *registry.PendingRequest) {
	ap := pr.Profile
	if ap == nil {
		return
	}
	ap.Mark(registry.StampFirstChunkDequeued)
	ap.Mark(registry.StampFirstContent)
	if t := pr.FirstContentIngressAtSafe(); !t.IsZero() {
		ap.MarkAt(registry.StampFirstContentIngress, t)
	}
	d.profile.SetHeldPreambleChunks(len(d.heldChunks))
}

// stampCommitted marks the winning attempt and, for streams, the
// headers-written offset (the SSE headers go out right after commit). A
// non-streaming response writes its headers with the body later, in
// writeNonStreamBody, so its offset is stamped there instead.
func (d *dispatchState) stampCommitted(pr *registry.PendingRequest) {
	if rp := d.profile; rp != nil && d.stream {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	if ap := pr.Profile; ap != nil {
		ap.Winning.Store(true)
	}
}

func closeUndispatchedAttempt(ap *registry.AttemptProfile, dispatchErr string, code int) {
	observation.CloseUndispatchedAttempt(ap, dispatchErrorClass(dispatchErr), code)
}

// finalizeProfile runs when the dispatch loop returns. It marks the handler
// half of every attempt; the terminal half (provider terminal, synthetic
// terminal, or grace expiry) completes each record independently.
func (d *dispatchState) finalizeProfile() {
	rp := d.profile
	if rp == nil {
		return
	}
	clientOutcome := "completed"
	switch {
	case d.r != nil && d.r.Context().Err() != nil:
		rp.Stamp(&rp.ClientGoneUS)
		clientOutcome = "client_gone"
	case !d.committed:
		clientOutcome = "error_response"
	}
	for _, ap := range rp.Attempts() {
		ap.SetOutcome("", "", "", "", clientOutcome)
		ap.CompleteHandler()
	}
}

// stampClientGone records a client disconnect with its phase.
func (d *dispatchState) stampClientGone(phase string) {
	rp := d.profile
	if rp == nil {
		return
	}
	rp.Stamp(&rp.ClientGoneUS)
	rp.SetClientGonePhase(phase)
}
