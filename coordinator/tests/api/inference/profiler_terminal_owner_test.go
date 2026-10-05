package inference_test

import (
	"net/http"
	"testing"
	"time"

	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestDuplicateErrorFrameAfterOwnedCompletionIsDropped pins terminal
// ownership across terminal TYPES. Completions settle on a worker goroutine
// while error frames run inline on the read loop, so an inference_error for a
// request whose completion already claimed the terminal used to remove the
// pending request, write the error outcome and settle — the row mixed the
// completion's usage/profile with the error frame's outcome. The error frame
// must instead fail its claim, be dropped as a duplicate without touching the
// pending request, and the completion must settle as the owner.
func TestDuplicateErrorFrameAfterOwnedCompletionIsDropped(t *testing.T) {
	const id = "dup-error-after-owned-completion"
	f := newClaimFixture(t, id, time.Now().Add(time.Minute), 0)
	f.pr.EnableSpeculativeEmptyCompletionArbitration()
	done := runClaimFrame(f, id)
	awaitClaimed(t, f)

	// The error frame lands on the read loop while the completion is parked
	// on arbitration. It carries a distinguishable profile so the row can
	// prove whose bytes it kept.
	f.srv.HandleInferenceError(f.provider.ID, f.provider, &protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		RequestID:   id,
		Error:       "provider aborted",
		StatusCode:  http.StatusInternalServerError,
		Profile:     []byte(`{"schema":1,"total_us":999}`),
		FailureCode: protocol.FailureCodeGenerationFailure,
	})
	if f.provider.GetPending(id) != f.pr {
		t.Fatal("a duplicate error frame must leave the pending request to the terminal's owner")
	}
	if n := f.srv.observation.UnknownRequestFrames(); n != 1 {
		t.Fatalf("duplicate error must be counted as an unknown-request frame once, got %d", n)
	}
	if fs, er, tc, po, co := f.ap.Outcome(); fs != "" || er != "" || tc != "" || po != "" || co != "" {
		t.Fatalf("a dropped error frame must write no outcome, got %q/%q/%q/%q/%q", fs, er, tc, po, co)
	}
	if raw, _ := f.ap.ProviderProfileRaw(); string(raw) != claimTestProfile {
		t.Fatalf("the owner's profile must be kept, got %s", raw)
	}
	select {
	case <-done:
		t.Fatal("completion settled before arbitration")
	default:
	}

	f.pr.ResolveSpeculativeEmptyCompletion(true)
	awaitClosed(t, done, "owned completion did not settle after arbitration")
	if f.provider.GetPending(id) != nil {
		t.Fatal("the owner must have removed the pending request when settling")
	}
	rec := awaitClaimRecord(t, f)
	assertClaimRow(t, rec, &store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusSuccess})
	if rec.ProvTotalUS == nil || *rec.ProvTotalUS != 1000 {
		t.Fatalf("row must carry the completion's profile, not the error frame's: total_us=%v", rec.ProvTotalUS)
	}
	select {
	case usage := <-f.pr.CompleteCh:
		if usage.PromptTokens != 100 {
			t.Fatalf("consumer received usage %+v", usage)
		}
	default:
		t.Fatal("the owning completion must reach the consumer")
	}
}
