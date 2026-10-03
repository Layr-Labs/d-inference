package inference

import (
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestClaimedErrorFrameFinalizesAfterPendingRemoved pins the error-frame twin
// of the completion claim window: the frame claims the terminal at the peek
// and retains its profile there, a consumer-side remover takes the pending
// request before the frame's own RemovePending, and the frame returns through
// the unknown-request path — which must close the claimed record
// (provider_outcome=error) carrying the profile it already retained, or the
// attempt never finalizes and the profile is recorded absent.
//
// There is no point between the peek-claim and RemovePending a test can hold,
// and both lookups are keyed on msg.RequestID (so the deadline-late
// id-rebinding trick cannot produce a hit-then-miss here). The remover
// therefore races the frame, biased by the provider's own pending-map mutex:
// the test holds it, lets the parked frame through its GetPending only in
// brief unlock/lock gaps, and once the claim is visible (possible only after
// that GetPending hit) releases and removes the pending — the frame's own
// RemovePending, reached a few hundred nanoseconds later or already parked
// behind the test, misses. An iteration the frame still won is discarded and
// retried on a fresh pending; the measured hit rate is well over half, so the
// bound is never approached.
func TestClaimedErrorFrameFinalizesAfterPendingRemoved(t *testing.T) {
	const errorProfile = `{"schema":1,"total_us":999}`
	const attempts = 300
	srv := newProfilerTestServer(t)
	for i := 0; i < attempts; i++ {
		id := "claimed-error-frame-" + strconv.Itoa(i)
		f := newClaimFixtureOn(t, srv, id, time.Now().Add(time.Minute), 0)
		before := srv.observation.UnknownRequestFrames()
		mu := f.provider.Mu()
		mu.Lock()
		done := make(chan struct{})
		go func() {
			srv.HandleInferenceError(f.provider.ID, f.provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   id,
				Error:       "provider aborted",
				StatusCode:  http.StatusInternalServerError,
				Profile:     []byte(errorProfile),
				FailureCode: protocol.FailureCodeGenerationFailure,
			})
			close(done)
		}()
		deadline := time.Now().Add(2 * time.Second)
		for !f.ap.TerminalClaimed() {
			if time.Now().After(deadline) {
				mu.Unlock()
				t.Fatal("error frame never claimed the terminal")
			}
			mu.Unlock() // let the parked frame through its GetPending …
			mu.Lock()   // … and hold the map again ahead of its RemovePending
		}
		// The consumer-side remover: the frame owns the claim and is between
		// retention and its own RemovePending (or parked on this mutex).
		mu.Unlock()
		removed := f.provider.RemovePending(id) != nil
		awaitClosed(t, done, "error frame did not return")
		if !removed {
			// The frame's own RemovePending won: normal path, window not hit.
			f.ap.CompleteHandler()
			continue
		}
		t.Logf("remover won the claim→RemovePending window on iteration %d", i)
		if n := srv.observation.UnknownRequestFrames() - before; n != 1 {
			t.Fatalf("frame must have returned through the unknown-request path exactly once, got %d", n)
		}
		if raw, _ := f.ap.ProviderProfileRaw(); string(raw) != errorProfile {
			t.Fatalf("profile must be retained at the peek claim, got %q", raw)
		}
		rec := awaitClaimRecord(t, f)
		if rec.ProviderOutcome != "error" || rec.FinalStatus != "error" {
			t.Fatalf("row = %q/%q, want error/error", rec.ProviderOutcome, rec.FinalStatus)
		}
		if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" || rec.ProvTotalUS == nil || *rec.ProvTotalUS != 999 {
			t.Fatalf("profile sent with the error frame must be retained and valid: valid=%v reason=%q total_us=%v",
				rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, rec.ProvTotalUS)
		}
		select {
		case e := <-f.pr.ErrorCh:
			t.Fatalf("error published to a consumer that had left: %+v", e)
		default:
		}
		return
	}
	t.Fatalf("the remover never won the claim→RemovePending window in %d attempts", attempts)
}
