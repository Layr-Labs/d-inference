package api

// Served-attempt settlement (settleCompletion): the primary and backup racers
// of a speculative dispatch copy ONE TokenAdmission and share its once-guard,
// so whichever terminal claimed it first used to settle the whole request. A
// loser whose content chunk lost the race but whose terminal reached
// handleCompleteAt before cancelDispatch removed it claimed the settlement
// with its own truncated usage; the winner's real completion was then skipped.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func admitForRace(t *testing.T, srv *Server, account string, bound int) registry.TokenAdmission {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.WithValue(context.Background(), ctxKeyConsumer, account))
	adm, ok := srv.applyTokenRateLimitWithAdmission(httptest.NewRecorder(), r, 10, bound, "m")
	if !ok {
		t.Fatal("admission rejected")
	}
	return adm
}

// TestSettlementFollowsTheServedAttempt: a losing racer's terminal (content
// chunk in flight, 2 tokens, never committed) must not settle the shared
// admission; the winner's terminal (committed, 4,000 tokens) must. Before the
// fix the loser's frame credited 32,768 − 2 and the winner's reconcile found
// the guard already claimed: the bucket read a full 64,000 after a
// 4,000-token answer.
func TestSettlementFollowsTheServedAttempt(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	const account = "acct-race"
	adm := admitForRace(t, srv, account, 32_768)
	charged := remainingOutput(t, tl, account)
	if charged > 64_000-32_768+5 {
		t.Fatalf("remaining after admission = %d, want ~%d", charged, 64_000-32_768)
	}
	// Both racers carry copies of the same admission (shared once-guard), as
	// dispatchWithReserver builds them.
	primary := &registry.PendingRequest{RequestID: "race-primary", Model: "m", ConsumerKey: account, TokenAdmission: adm}
	backup := &registry.PendingRequest{RequestID: "race-backup", Model: "m", ConsumerKey: account, TokenAdmission: adm}

	// The backup produced a content chunk that lost the race, and its terminal
	// reached the read loop before cancelDispatch's RemovePending.
	now := time.Now()
	backup.FinishProviderChunkIngress(now, true)
	srv.settleCompletion(backup, 2, false)
	if got := remainingOutput(t, tl, account); got < charged-5 || got > charged+5 {
		t.Fatalf("the losing racer's terminal moved the bucket: %d -> %d (it claimed the shared settlement with 2 tokens)", charged, got)
	}

	// The primary is committed, then completes with 4,000 tokens.
	primary.FinishProviderChunkIngress(now, true)
	if _, settle := primary.MarkContentCommitted(); settle {
		t.Fatal("nothing was parked on the primary yet")
	}
	srv.settleCompletion(primary, 4_000, false)
	if got := remainingOutput(t, tl, account); got < 64_000-4_000-5 || got > 64_000-4_000+5 {
		t.Fatalf("remaining after the served completion = %d, want ~%d (32,768 charged, 4,000 used); the winner's settlement was skipped", got, 64_000-4_000)
	}
	// The calibrator saw the winner's count only.
	if _, _, obs := srv.registry.CompletionCalibrationPercentiles("m"); obs != 1 {
		t.Fatalf("calibrator observations = %d, want 1 (the loser's truncated 2-token sample must not be fed)", obs)
	}
}

// TestTerminalThatOutransTheCommitSettlesAtCommit: a fast single-chunk
// completion's terminal reaches the read loop before the dispatch goroutine
// commits the chunk. The terminal parks its tokens; the REAL commitFirstContent
// settles them — so the lane's credit-back still lands for exactly the short
// completions it was built for.
func TestTerminalThatOutransTheCommitSettlesAtCommit(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	const account = "acct-fast"
	adm := admitForRace(t, srv, account, 32_768)
	charged := remainingOutput(t, tl, account)
	pr := &registry.PendingRequest{RequestID: "fast", Model: "m", ConsumerKey: account, TokenAdmission: adm,
		Timing: &registry.RequestTiming{ReceivedAt: time.Now()}}
	pr.FinishProviderChunkIngress(time.Now(), true)

	// Terminal first: nothing settles yet.
	srv.settleCompletion(pr, 300, false)
	if got := remainingOutput(t, tl, account); got < charged-5 || got > charged+5 {
		t.Fatalf("an uncommitted attempt's terminal settled: %d -> %d", charged, got)
	}
	// Then the dispatch goroutine commits the chunk through commitFirstContent.
	d := &dispatchState{s: srv, model: "m"}
	d.commitFirstContent(pr, "data: {}")
	if got := remainingOutput(t, tl, account); got < 64_000-300-5 || got > 64_000-300+5 {
		t.Fatalf("remaining after the commit = %d, want ~%d: the parked terminal was not settled at commit", got, 64_000-300)
	}
	if _, _, obs := srv.registry.CompletionCalibrationPercentiles("m"); obs != 1 {
		t.Fatalf("calibrator observations = %d, want 1", obs)
	}
	// A second commit or terminal cannot settle again.
	if _, settle := pr.MarkContentCommitted(); settle {
		t.Fatal("parked tokens handed out twice")
	}
	srv.settleCompletion(pr, 300, false)
	if got := remainingOutput(t, tl, account); got > 64_000-300+5 {
		t.Fatalf("double settlement: remaining = %d", got)
	}
}

// TestEmptyAndParkedTerminalsStillSettle: an accepted empty completion (no
// content ever, so no commit will follow) and a parked after-commit
// client-gone record (consumerGone) settle immediately.
func TestEmptyAndParkedTerminalsStillSettle(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)

	empty := &registry.PendingRequest{RequestID: "empty", Model: "m", ConsumerKey: "acct-empty", TokenAdmission: admitForRace(t, srv, "acct-empty", 32_768)}
	srv.settleCompletion(empty, 0, false)
	if got := remainingOutput(t, tl, "acct-empty"); got < 64_000-5 {
		t.Fatalf("empty completion not settled: remaining = %d, want 64,000", got)
	}

	parked := &registry.PendingRequest{RequestID: "parked", Model: "m", ConsumerKey: "acct-parked", TokenAdmission: admitForRace(t, srv, "acct-parked", 32_768)}
	parked.FinishProviderChunkIngress(time.Now(), true)
	srv.settleCompletion(parked, 1_000, true)
	if got := remainingOutput(t, tl, "acct-parked"); got < 64_000-1_000-5 || got > 64_000-1_000+5 {
		t.Fatalf("parked (consumer gone) completion not settled: remaining = %d, want ~%d", got, 64_000-1_000)
	}
}
