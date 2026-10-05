package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
)

// TestQueueMaxTTFTMsSoftVsHard pins the soft/hard TTFT-gate contract that the
// dispatch layer feeds into the scheduler via PendingRequest.MaxTTFTMs.
//
// In soft mode (default) a public route gets a zero ceiling, which disables the
// scheduler's enforceTTFT path so a slow-but-eligible provider is still selected
// (see TestReserveProviderExcludesSlowProviderWhenTTFTCeilingSet: MaxTTFTMs==0
// selects the slow provider). In hard mode the public route inherits the
// prompt-scaled deadline so the legacy 429-on-slow-estimate behavior returns.
// Self-route and prefer-owner are never subject to the public SLA ceiling.
func TestQueueMaxTTFTMsSoftVsHard(t *testing.T) {
	deadline := 6 * time.Second
	public := dispatch.Scope{}

	if got := routeplan.QueueTTFTCeiling(public, deadline, false); got != 0 {
		t.Fatalf("soft public ceiling = %v, want 0 (no ceiling -> serve best-available)", got)
	}
	if got := routeplan.QueueTTFTCeiling(public, deadline, true); got != float64(deadline.Milliseconds()) {
		t.Fatalf("hard public ceiling = %v, want %d", got, deadline.Milliseconds())
	}

	for _, hardReject := range []bool{false, true} {
		if got := routeplan.QueueTTFTCeiling(dispatch.Scope{SelfRouteOnly: true}, deadline, hardReject); got != 0 {
			t.Fatalf("self-route ceiling (hardReject=%v) = %v, want 0", hardReject, got)
		}
		if got := routeplan.QueueTTFTCeiling(dispatch.Scope{PreferOwner: true}, deadline, hardReject); got != 0 {
			t.Fatalf("prefer-owner ceiling (hardReject=%v) = %v, want 0", hardReject, got)
		}
	}
}
