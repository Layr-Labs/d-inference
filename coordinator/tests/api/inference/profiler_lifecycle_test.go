package inference_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestTimingJSONAdditiveKeysAndClamp(t *testing.T) {
	newProfilerTestServer(t)
	rp := registry.NewRequestProfile(time.Now().Add(-time.Second), "c", nil, 0)
	rp.PreflightUS = 300
	rp.Stamp(&rp.HandlerEntryUS)
	ap := rp.NewAttempt("a", 0, "")
	ap.AttemptStartUS.Store(1000)
	ap.ReserveDoneUS.Store(1500)
	ap.WriteSubmittedUS.Store(2000)
	ap.WriteDequeuedUS.Store(2100)
	ap.WriteDoneUS.Store(2400)
	ap.AcceptedUS.Store(3400)
	pr := &registry.PendingRequest{Profile: ap}
	tj := types.RequestTimingDetails{ParseUs: -5, ProviderUs: 10}
	observation.ApplyProfileTiming(rp, &tj, pr)
	if tj.ParseUs != 0 || !tj.TimingAnomaly {
		t.Fatal("negative legacy segment must clamp to 0 and flag anomaly")
	}
	if tj.RouteReserveUs != 500 || tj.WriterUs != 100 || tj.SocketUs != 300 || tj.ProviderAckUs != 1000 || tj.PreflightUs != 300 {
		t.Fatalf("additive keys wrong: %+v", tj)
	}
	b, _ := json.Marshal(tj)
	for _, key := range []string{"parse_us", "provider_us", "route_reserve_us", "writer_us", "socket_us", "provider_ack_us", "preflight_us"} {
		if !json.Valid(b) || !containsKey(b, key) {
			t.Fatalf("X-Timing missing %s: %s", key, b)
		}
	}
}

func TestProfilerKillSwitchMakesEverySiteNoOp(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PROFILER", "off")
	srv := newProfilerTestServer(t)
	if srv.observation.ProfilerEnabled() {
		t.Fatal("kill switch must disable the profiler")
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if rp := srv.observation.NewRequestProfile(req, "m", "m", true); rp != nil {
		t.Fatal("no profile when off")
	}
	// Every stamp helper must be nil-safe.
	var rp *registry.RequestProfile
	rp.Mark(registry.StampReqParsed)
	rp.Stamp(nil)
	observation.ProfileDBCall(rp, time.Now())
	var ap *registry.AttemptProfile
	ap.Mark(registry.StampAccepted)
	ap.MarkAt(registry.StampCompleteIngress, time.Now())
	ap.SetDecision(registry.RoutingDecision{})
	ap.SetOutcome("x", "", "", "", "")
	ap.CompleteHandler()
	ap.CompleteTerminal()
	ap.ClaimTerminal()
	observation.CloseUndispatchedAttempt(ap, "provider_error", 503)
	pr := &registry.PendingRequest{}
	observation.ProfileClientGone(pr, "after_commit")
	observation.NewRelayStamps(pr.Profile.Parent()).Flushed(3)
	tj := types.RequestTimingDetails{ParseUs: -5}
	observation.ApplyProfileTiming(nil, &tj, pr)
	if tj.ParseUs != -5 || tj.TimingAnomaly {
		t.Fatal("with the profiler off the legacy X-Timing values must be untouched")
	}
	profile.Finalize(nil, nil, false)
	profile.StampFirstContent(nil, pr, 0)
	profile.StampCommitted(nil, pr, false)
}

func TestCloseUndispatchedAttemptCoversWriteFailure(t *testing.T) {
	var finalized int
	rp := registry.NewRequestProfile(time.Now(), "c", func(*registry.RequestProfile, *registry.AttemptProfile) { finalized++ }, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.Mark(registry.StampWriteSubmitted) // submitted, but the write failed: WriteDone never set
	observation.CloseUndispatchedAttempt(ap, "provider_error", 502)
	if finalized != 0 {
		t.Fatalf("closing an undispatched attempt must only complete the terminal half (the record is built after the handler returns), finalized=%d", finalized)
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if finalized != 1 {
		t.Fatalf("write-failed attempt must finalize once the handler half lands, finalized=%d", finalized)
	}
	fs, _, _, po, _ := ap.Outcome()
	if fs != "error" || po != "not_dispatched" {
		t.Fatalf("outcome %q/%q", fs, po)
	}
	ok := rp.NewAttempt("b", 1, "")
	ok.Mark(registry.StampWriteDone)
	observation.CloseUndispatchedAttempt(ok, "provider_error", 500)
	if ok.Finalized() {
		t.Fatal("a dispatched attempt must be left to its provider terminal")
	}
}
