package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The API kill-switch fixture still checks configuration, request metadata and
// actual relay behavior. These are its unchanged nil-profile dispatch sites.
func TestDispatchNilProfilePreservesLegacyTiming(t *testing.T) {
	srv := newTestController(t)
	var ap *registry.AttemptProfile
	closeUndispatchedAttempt(ap, "e", 503)
	pr := &registry.PendingRequest{}
	d := &execution{s: srv}
	tj := types.RequestTimingDetails{ParseUs: -5}
	d.applyProfileTiming(&tj, pr)
	if tj.ParseUs != -5 || tj.TimingAnomaly {
		t.Fatal("with the profiler off the legacy X-Timing values must be untouched")
	}
	d.finalizeProfile()
	d.stampFirstContent(pr)
	d.stampCommitted(pr)
}
