package inference

import (
	"encoding/json"
	"net/http"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
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

// stampCommitted marks the winning attempt and, for streams, the
// headers-written offset (the SSE headers go out right after commit). A
// non-streaming response writes its headers with the body later, in
// writeNonStreamBody, so its offset is stamped there instead.
func (d *dispatchState) stampCommitted(pr *registry.PendingRequest) {
	profile.StampCommitted(d.profile, pr, d.stream)
}

func closeUndispatchedAttempt(ap *registry.AttemptProfile, dispatchErr string, code int) {
	profile.CloseUndispatched(ap, dispatchErr, code)
}

// finalizeProfile runs when the dispatch loop returns. It marks the handler
// half of every attempt; the terminal half (provider terminal, synthetic
// terminal, or grace expiry) completes each record independently.
func (d *dispatchState) finalizeProfile() {
	profile.Finalize(d.profile, d.r, d.committed)
}
