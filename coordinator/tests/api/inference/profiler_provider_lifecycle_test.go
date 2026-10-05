package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	profilepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestCompleteHandlerFinalizesTerminalAfterSettlement pins the terminal-half
// ordering of the complete handler on both branches: the attempt must not
// finalize (and so be enqueued to the sink) before the settlement stamp has
// landed. The PARKED branch (consumer already gone; claimSettlement returned
// the parked record) used to complete the terminal inside the billing gate,
// before the stamp, so settle_db_us was nondeterministically missing on rows
// for completed-after-disconnect requests.
func TestCompleteHandlerFinalizesTerminalAfterSettlement(t *testing.T) {
	for _, parked := range []bool{true, false} {
		name := "live"
		if parked {
			name = "parked"
		}
		t.Run(name, func(t *testing.T) {
			srv, _, ledger := billingTestServer(t)
			// Long grace: handleComplete deterministically claims the parked
			// record first; the timer fires after the test and no-ops.
			srv.late.Grace = 5 * time.Second
			model := "settle-order-model"
			provider := srv.registry.Register("settle-order-"+name, nil, &protocol.RegisterMessage{
				Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
			})
			provider.Mu().Lock()
			provider.AccountID = "settle-order-account"
			provider.Mu().Unlock()

			usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
			const reserved int64 = 5_000_000
			if err := ledger.Charge(testConsumerID, reserved, "reserve:settle-order-"+name); err != nil {
				t.Fatalf("reserve balance: %v", err)
			}
			pr := &registry.PendingRequest{
				RequestID:        "settle-order-" + name,
				Model:            model,
				ConsumerKey:      testConsumerID,
				ReservedMicroUSD: reserved,
				ChunkCh:          make(chan registry.ProviderChunk, 1),
				CompleteCh:       make(chan protocol.UsageInfo, 1),
				ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
			}
			type terminalSnapshot struct {
				settleDBUS, completeIngressUS int64
				providerOutcome               string
			}
			finalized := make(chan terminalSnapshot, 2)
			rp := registry.NewRequestProfile(time.Now(), "coord-"+name, func(_ *registry.RequestProfile, ap *registry.AttemptProfile) {
				// Snapshot on the finalizing goroutine, not the later sink worker:
				// an early finalization must not be hidden by a subsequent stamp.
				_, _, _, providerOutcome, _ := ap.Outcome()
				finalized <- terminalSnapshot{ap.SettleDBUS.Load(), ap.CompleteIngressUS.Load(), providerOutcome}
			}, 0)
			ap := rp.NewAttempt(pr.RequestID, 0, "")
			ap.ProviderID = provider.ID
			pr.Profile = ap
			// The handler half is already done (the consumer-side handler has
			// returned), so the terminal half finalizes the attempt wherever
			// handleComplete runs CompleteTerminal.
			ap.CompleteHandler()

			if parked {
				parkConsumerGone(srv, provider, pr)
			} else {
				provider.AddPending(pr)
			}
			srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: pr.RequestID,
				Usage:     usage,
			}, time.Now())

			var rec terminalSnapshot
			select {
			case rec = <-finalized:
			case <-time.After(2 * time.Second):
				t.Fatal("attempt never finalized")
			}
			if rec.settleDBUS == 0 {
				t.Fatal("attempt finalized before the settlement stamp: settle_db_us missing")
			}
			if rec.providerOutcome != "completed" || rec.completeIngressUS == 0 {
				t.Fatalf("provider_outcome=%q complete_ingress=%v", rec.providerOutcome, rec.completeIngressUS)
			}
			if p, c, ok := ap.TerminalUsage(); !ok || p != usage.PromptTokens || c != usage.CompletionTokens {
				t.Fatalf("terminal usage = %d/%d ok=%v, want %d/%d recorded at ingress", p, c, ok, usage.PromptTokens, usage.CompletionTokens)
			}
			select {
			case <-finalized:
				t.Fatal("attempt finalized twice")
			default:
			}
			if !parked {
				// The consumer was signalled before the terminal half completed.
				select {
				case got := <-pr.CompleteCh:
					if got.CompletionTokens != usage.CompletionTokens {
						t.Fatalf("consumer got usage %+v", got)
					}
				default:
					t.Fatal("live consumer was not signalled")
				}
			}
		})
	}
}

// TestCloseQueuedAttemptKeepsRecordedErrorText pins the defaulting rule of the
// queue-path close: a real error text with no HTTP status keeps its own class
// (only the code is defaulted); an exit that recorded nothing is classified by
// how the wait ended; a dispatched attempt is left to its provider terminal.
func TestCloseQueuedAttemptKeepsRecordedErrorText(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	newReq := func() *http.Request { return httptest.NewRequest(http.MethodPost, "/v1/completions", nil) }

	r := newReq()
	enc := rp.NewAttempt("enc", 0, "")
	profilepolicy.CloseQueued(r.Context(), enc, "no provider with E2E encryption", 0)
	if _, reason, _, po, _ := enc.Outcome(); reason != "encryption_missing" || po != "not_dispatched" {
		t.Fatalf("encryption failure recorded as %q/%q, want encryption_missing/not_dispatched", reason, po)
	}

	r = newReq()
	none := rp.NewAttempt("none", 1, "")
	profilepolicy.CloseQueued(r.Context(), none, "", 0)
	if fs, reason, _, po, _ := none.Outcome(); fs != "rejected" || reason != "provider_error" || po != "not_dispatched" {
		t.Fatalf("queue refusal recorded as %q/%q/%q", fs, reason, po)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r = newReq().WithContext(ctx)
	gone := rp.NewAttempt("gone", 2, "")
	profilepolicy.CloseQueued(r.Context(), gone, "", 0)
	if fs, _, _, po, _ := gone.Outcome(); fs != "cancelled" || po != "not_dispatched" {
		t.Fatalf("client gone while queued recorded as %q/%q", fs, po)
	}

	r = newReq()
	sent := rp.NewAttempt("sent", 3, "")
	sent.Mark(registry.StampWriteDone)
	profilepolicy.CloseQueued(r.Context(), sent, "failed to send request to provider", 0)
	if fs, _, _, po, _ := sent.Outcome(); fs != "" || po != "" || sent.TerminalRecorded() {
		t.Fatalf("a dispatched attempt must be left alone: %q/%q terminal=%v", fs, po, sent.TerminalRecorded())
	}
}

// TestSpeculativeLoserCompletionKeepsFunnelOutcome pins the provider-side half
// of a losing speculative racer's empty completion: the read loop records only
// provider_outcome (completed for a frame that reached the wire, nothing for
// one that never did), retains the usage and profile that arrived with the
// completion, and leaves final_status/error_reason to the dispatch side — the
// route-outcome funnel (markSpeculativeLoser → speculativeLoserOutcome, whose
// closed error_class "speculative_loser" is what the row carries) or, for an
// unsent frame, closeUndispatchedAttempt (not_dispatched). Both goroutine
// orders must produce the identical row: that is the proof there is no
// first-write race and no vocabulary drift between the two writers.
func TestSpeculativeLoserCompletionKeepsFunnelOutcome(t *testing.T) {
	cases := []struct {
		name        string
		dispatched  bool
		readerFirst bool
		wantOutcome string
		wantStatus  string
		wantReason  string
	}{
		{"dispatched, funnel first", true, false, "completed", "cancelled", ""}, // reason: profileErrorReason(speculativeLoserOutcome(pr))
		{"dispatched, reader first", true, true, "completed", "cancelled", ""},
		{"unsent, close first", false, false, "not_dispatched", "error", "provider_error"},
		{"unsent, reader first", false, true, "not_dispatched", "error", "provider_error"},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := newProfilerTestServer(t)
			id := "spec-loser-" + strconv.Itoa(i)
			provider := srv.registry.Register(id, nil, &protocol.RegisterMessage{
				Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
			})
			pr := &registry.PendingRequest{
				RequestID:            id,
				Model:                "m",
				FirstContentDeadline: time.Now().Add(time.Minute),
				ChunkCh:              make(chan registry.ProviderChunk, 1),
				CompleteCh:           make(chan protocol.UsageInfo, 1),
				ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
			}
			rp := observedTestProfile(t, srv, time.Now(), "coord-"+id)
			ap := rp.NewAttempt(pr.RequestID, 0, "")
			ap.ProviderID = provider.ID
			ap.Mark(registry.StampWriteSubmitted)
			if tc.dispatched {
				ap.Mark(registry.StampWriteDone)
			}
			pr.Profile = ap
			pr.EnableSpeculativeEmptyCompletionArbitration()
			provider.AddPending(pr)

			done := make(chan struct{})
			go func() {
				srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: pr.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 100},
					Profile:   []byte(`{"schema":1,"total_us":1000,"prompt_tokens":100}`),
				}, time.Now())
				close(done)
			}()
			<-pr.CompletionIngressSignal()
			select {
			case <-done:
				t.Fatal("empty completion settled before speculative arbitration")
			default:
			}
			awaitReader := func() {
				select {
				case <-done:
				case <-time.After(2 * time.Second):
					t.Fatal("rejected empty completion did not release the read loop")
				}
			}
			dispatchSide := func() {
				if tc.dispatched {
					srv.NewRouteRecorder().SpeculativeLoser(pr)
				} else {
					profilepolicy.CloseUndispatched(ap, "failed to send request to provider", http.StatusBadGateway)
				}
			}
			release := func() {
				if tc.dispatched {
					pr.ResolveSpeculativeEmptyCompletion(false) // what cancelDispatch does for the loser
					provider.RemovePending(pr.RequestID)
				} else {
					firstcontent.ReleaseUnsent(srv.registry, provider, pr)
				}
			}
			if tc.readerFirst {
				release()
				awaitReader()
				dispatchSide()
			} else {
				dispatchSide()
				release()
				awaitReader()
			}

			if ap.Finalized() {
				t.Fatal("attempt finalized before the handler half")
			}
			ap.CompleteHandler()
			rec := awaitPersistedProfile(t, srv, ap)
			wantReason := tc.wantReason
			if tc.dispatched {
				loser := routeoutcome.SpeculativeLoserOutcome(pr)
				if loser.FinalStatus != tc.wantStatus || loser.ErrorClass != "speculative_loser" || loser.ErrorReason == "" {
					t.Fatalf("speculativeLoserOutcome = %+v", loser)
				}
				wantReason = routeoutcome.ProfileErrorReason(loser) // the routes error_class vocabulary
			}
			if rec.ProviderOutcome != tc.wantOutcome || rec.FinalStatus != tc.wantStatus || rec.ErrorReason != wantReason {
				t.Fatalf("row = %q/%q/%q, want %s/%s/%s", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason, tc.wantOutcome, tc.wantStatus, wantReason)
			}
			if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" {
				t.Fatalf("profile sent with the losing completion must be retained: valid=%v reason=%q", rec.ProviderProfileValid, rec.ProviderProfileInvalidReason)
			}
			if rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
				t.Fatalf("terminal usage must be recorded for the loser: consistent=%v", rec.ProviderProfileConsistent)
			}
			if p, _, ok := ap.TerminalUsage(); !ok || p != 100 {
				t.Fatalf("terminal usage = %d ok=%v", p, ok)
			}
			select {
			case <-pr.CompleteCh:
				t.Fatal("losing completion was published to the consumer")
			default:
			}
		})
	}
}

func TestClaimedCompleteFrameFinalizesAfterPendingRemoved(t *testing.T) {
	newFixture := func(t *testing.T, id string, deadline time.Time) claimFixture {
		return newClaimFixture(t, id, deadline, 0)
	}
	runFrame, await, awaitRecord, assertRow := runClaimFrame, awaitClosed, awaitClaimRecord, assertClaimRow

	t.Run("arbitration window, client gone", func(t *testing.T) {
		const id = "claim-window-client-gone"
		f := newFixture(t, id, time.Now().Add(time.Minute))
		f.pr.EnableSpeculativeEmptyCompletionArbitration()
		done := runFrame(f, id)
		awaitClaimed(t, f)
		select {
		case <-done:
			t.Fatal("empty completion settled before speculative arbitration")
		default:
		}
		// The consumer-side cleanup lands while the frame is parked on the
		// arbitration: pending removed, cancelled through the funnel (which
		// leaves the claimed terminal to the frame), then the frame is released
		// and finds nothing to settle.
		if f.provider.RemovePending(id) != f.pr {
			t.Fatal("pending request was not in the provider's set")
		}
		want := routeoutcome.ClientGoneBeforeResponseOutcome(f.pr)
		f.srv.NewRouteRecorder().Pending(f.pr, want)
		f.pr.ResolveSpeculativeEmptyCompletion(true)
		await(t, done, "released completion frame did not return")
		if n := f.srv.observation.UnknownRequestFrames(); n != 1 {
			t.Fatalf("frame must have returned through the unknown-request path, unknown frames=%d", n)
		}
		rec := awaitRecord(t, f)
		assertRow(t, rec, want)
		if f.provider.GetPending(id) != nil {
			t.Fatal("pending request must stay removed")
		}
		select {
		case <-f.pr.CompleteCh:
			t.Fatal("completion was published to a consumer that had left")
		default:
		}
	})

	t.Run("deadline-late, pending gone before handleInferenceError", func(t *testing.T) {
		const id = "claim-window-deadline-late"
		f := newFixture(t, id, time.Now().Add(-time.Second)) // past deadline, no first content
		// There is no synchronization point a test can hold between the claim
		// and the deadline-late handleInferenceError call, so the concurrent
		// remover is stood in for by rebinding the request id before the frame
		// starts: GetPending (keyed by the registered id) still hits and claims,
		// while handleInferenceError's RemovePending/claimSettlement (keyed by
		// pending.RequestID) miss — exactly the state a remover that won the
		// window leaves behind. The write happens-before the goroutine start.
		f.pr.RequestID = id + "-removed"
		defer f.provider.RemovePending(id)
		done := runFrame(f, id)
		await(t, done, "deadline-late completion frame did not return")
		if !f.ap.TerminalClaimed() {
			t.Fatal("the frame must own the terminal claim at ingress")
		}
		if n := f.srv.observation.UnknownRequestFrames(); n != 1 {
			t.Fatalf("handleInferenceError must have taken the unknown-request path, unknown frames=%d", n)
		}
		// The dispatch side classifies the timeout through the funnel, which
		// leaves the claimed terminal to the frame.
		want := routeoutcome.PreResponseTimeoutOutcome(f.pr, "first_chunk_timeout")
		f.srv.NewRouteRecorder().Pending(f.pr, want)
		rec := awaitRecord(t, f)
		assertRow(t, rec, want)
		select {
		case <-f.pr.CompleteCh:
			t.Fatal("deadline-late completion was published to the consumer")
		default:
		}
	})
}

// TestRefundWinsCompletionKeepsProviderOutcome pins the refund-wins ordering:
// the consumer relay's timeout finalizes (refunds) the reservation after the
// completion frame claimed the terminal but before it settles. The billing
// gate is then skipped, and the only in-gate provider-outcome write with it,
// so the deferred CompleteTerminal used to close the record with an empty
// provider_outcome. The frame must record "completed" outside the gate and
// still carry its usage and profile; final_status comes from the timeout the
// relay classified through the funnel.
func TestRefundWinsCompletionKeepsProviderOutcome(t *testing.T) {
	const id = "refund-wins-completion"
	f := newClaimFixture(t, id, time.Now().Add(time.Minute), 2_000_000)
	f.pr.EnableSpeculativeEmptyCompletionArbitration()
	done := runClaimFrame(f, id)
	awaitClaimed(t, f)

	// What the relay's timer branch does (consumer.go): refund, then classify.
	if !f.srv.reservations.Refund(f.pr, "provider_timeout:"+id) {
		t.Fatal("the timeout refund must finalize the reservation before the completion settles")
	}
	want := routeoutcome.PostCommitStreamTimeoutOutcome(f.pr)
	f.srv.NewRouteRecorder().Pending(f.pr, want)
	select {
	case <-done:
		t.Fatal("completion settled before arbitration")
	default:
	}

	f.pr.ResolveSpeculativeEmptyCompletion(true)
	awaitClosed(t, done, "completion did not settle after the refund")
	if !f.pr.IsReservationFinalized() {
		t.Fatal("reservation must stay finalized by the refund")
	}
	rec := awaitClaimRecord(t, f)
	assertClaimRow(t, rec, want)
	if p, _, ok := f.ap.TerminalUsage(); !ok || p != 100 {
		t.Fatalf("terminal usage must be recorded outside the billing gate: %d ok=%v", p, ok)
	}
}
