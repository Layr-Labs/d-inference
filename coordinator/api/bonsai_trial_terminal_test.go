package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/trial"
)

func TestBonsaiTrialOwnedPartialProviderErrorDoesNotPayOrConsume(t *testing.T) {
	for _, status := range []int{499, 500} {
		s, st := bonsaiUnitServer(t)
		s.settleGrace = time.Hour
		pr, provider := bonsaiUnitPending(t, s, "owner")
		provider.Mu().Lock()
		provider.AccountID = "owner"
		provider.Mu().Unlock()
		pr.PreferOwner, pr.OwnerAccountID = true, "owner"
		pr.MarkContentCommitted()
		parkConsumerGone(s, provider, pr)
		s.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
			Type: protocol.TypeInferenceError, RequestID: pr.RequestID, StatusCode: status,
			Error: "request cancelled", AttemptUsage: &protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 10},
		})
		a, err := st.GetTrialAllowance(context.Background(), "owner", s.bonsaiTrial.CampaignID)
		if err != nil || a.UsedTokens != 0 || a.ReservedTokens != 0 {
			t.Fatalf("owned partial request consumed quota: %+v, %v", a, err)
		}
		if got := st.GetWithdrawableBalance("owner"); got != 0 {
			t.Fatalf("owned partial request manufactured payout: %d", got)
		}
	}
}

func TestBonsaiTrialCommittedContentMissingUsageRemainsUnresolved(t *testing.T) {
	for _, path := range []string{"completion", "error with zero usage", "error with omitted usage"} {
		t.Run(path, func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			s.settleGrace = time.Hour
			pr, provider := bonsaiUnitPending(t, s, "account")
			pr.MarkContentCommitted()
			parkConsumerGone(s, provider, pr)
			if path == "completion" {
				s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID})
			} else {
				msg := &protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: pr.RequestID, StatusCode: 499, Error: "request cancelled"}
				if path == "error with zero usage" {
					msg.AttemptUsage = &protocol.UsageInfo{}
				}
				s.handleInferenceError(provider.ID, provider, msg)
			}
			r, err := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
			if err != nil || r.State != store.TrialUnresolved {
				t.Fatalf("unaccounted generated tokens must retain hold: %+v, %v", r, err)
			}
			if st.GetWithdrawableBalance(provider.AccountID) != 0 || len(st.UsageByConsumer("account")) != 0 {
				t.Fatal("missing usage produced payout or zero-token usage record")
			}
		})
	}
}

func TestBonsaiTrialPreferOwnerCustomPriceCannotBlockFreeOwnedDispatch(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "owner"))
	if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 100); err != nil {
		t.Fatal(err)
	}
	provider := &registry.Provider{ID: "owned-provider", AccountID: "owner"}
	if err := st.SetModelPrice("owner", trial.BonsaiBuildID, 999_000, 999_000); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{Model: trial.BonsaiBuildID, ConsumerKey: "owner", OwnerAccountID: "owner", PreferOwner: true, TrialReservation: trialReservationFromRequest(r), TrialUnusedConfirmed: trialUnusedFromRequest(r)}
	if err := s.markTrialDispatched(pr, provider); err != nil {
		t.Fatalf("free owned route rejected by irrelevant paid price: %v", err)
	}
}

func TestBonsaiTrialAmbiguousDispatchedCleanupRetainsHold(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	pr, _ := bonsaiUnitPending(t, s, "account")
	// No first content has reached this coordinator, but dispatch has occurred.
	// Loss of the connection is not proof that the provider did no work.
	s.refundReservedBalance(pr, "no_terminal_after_cancel:"+pr.RequestID)
	r, err := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
	if err != nil || r.State != store.TrialUnresolved {
		t.Fatalf("ambiguous dispatched request released quota: %+v, %v", r, err)
	}
}

func TestBonsaiTrialErrorAttemptUsageCannotAuthorizePublicPayout(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	s.settleGrace = time.Hour
	pr, provider := bonsaiUnitPending(t, s, "account")
	pr.MarkContentCommitted()
	parkConsumerGone(s, provider, pr)
	s.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
		Type: protocol.TypeInferenceError, RequestID: pr.RequestID, StatusCode: 499, Error: "request cancelled",
		AttemptUsage: &protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 10},
	})
	r, err := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
	if err != nil || r.State != store.TrialUnresolved {
		t.Fatalf("observability-only attempt usage settled hold: %+v, %v", r, err)
	}
	if st.GetWithdrawableBalance(provider.AccountID) != 0 || len(st.UsageByConsumer("account")) != 0 {
		t.Fatal("observability-only error usage produced a payment")
	}
}

func TestBonsaiTrialUsageSubtotalsDoNotDoubleCount(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	pr, provider := bonsaiUnitPending(t, s, "account")
	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500, ReasoningTokens: 400, CachedTokens: 900, PrefillTokensSaved: 800}
	if !s.settleBonsaiTrial(pr, provider, usage, false) {
		t.Fatal("valid subtotal usage rejected")
	}
	a, err := st.GetTrialAllowance(context.Background(), "account", s.bonsaiTrial.CampaignID)
	if err != nil || a.UsedTokens != 1500 {
		t.Fatalf("subtotals counted again: %+v, %v", a, err)
	}
}

func TestBonsaiTrialNoWorkTerminalProofControlsReleaseAndRetry(t *testing.T) {
	for _, scenario := range []string{"provider no content", "synthetic no content", "tagged synthetic", "provider after content", "missing terminal"} {
		t.Run(scenario, func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "account"))
			if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 100); err != nil {
				t.Fatal(err)
			}
			provider := &registry.Provider{ID: "provider", AccountID: "provider-account"}
			pr := &registry.PendingRequest{RequestID: "attempt", Model: trial.BonsaiBuildID, ConsumerKey: "account", TrialReservation: trialReservationFromRequest(r), TrialUnusedConfirmed: trialUnusedFromRequest(r)}
			if err := s.markTrialDispatched(pr, provider); err != nil {
				t.Fatal(err)
			}
			if pr.TrialUnusedConfirmed.Load() {
				t.Fatal("dispatch retained unused proof")
			}
			if scenario == "provider after content" {
				pr.MarkContentCommitted()
			}
			msg := &protocol.InferenceErrorMessage{StatusCode: 503, Error: "provider rejected request"}
			if scenario == "tagged synthetic" {
				msg.CoordinatorCause = "synthetic"
			}
			if scenario != "missing terminal" {
				s.handleBonsaiTrialError(pr, provider, msg, scenario != "synthetic no content")
			}
			confirmed := scenario == "provider no content"
			if pr.TrialUnusedConfirmed.Load() != confirmed {
				t.Fatal("incorrect no-work evidence")
			}
			s.finishTrialRequest(r)
			got, err := st.GetTrialReservation(r.Context(), pr.TrialReservation.ID)
			want := store.TrialUnresolved
			if confirmed {
				want = store.TrialReleased
			}
			if err != nil || got.State != want {
				t.Fatalf("cleanup state=%s want=%s err=%v", got.State, want, err)
			}
		})
	}
}

func TestBonsaiTrialSequentialRetryRequiresConfirmedPriorNoWork(t *testing.T) {
	for _, confirmed := range []bool{false, true} {
		s, st := bonsaiUnitServer(t)
		pr, provider := bonsaiUnitPending(t, s, "account")
		if confirmed {
			s.handleBonsaiTrialError(pr, provider, &protocol.InferenceErrorMessage{StatusCode: 503}, true)
		}
		err := s.markTrialDispatched(pr, provider)
		if (err == nil) != confirmed {
			t.Fatalf("confirmed=%v retry err=%v", confirmed, err)
		}
		if pr.TrialUnusedConfirmed.Load() {
			t.Fatal("retry did not clear prior proof")
		}
		got, getErr := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
		want := store.TrialUnresolved
		if confirmed {
			want = store.TrialDispatched
		}
		if getErr != nil || got.State != want {
			t.Fatalf("confirmed=%v state=%s err=%v", confirmed, got.State, getErr)
		}
	}
}
