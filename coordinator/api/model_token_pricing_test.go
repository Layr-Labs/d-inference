package api

import (
	"math"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestModelTokenPromotionExactPricing(t *testing.T) {
	fee := int64(20)
	for _, tt := range []struct {
		name           string
		prompt, output int
		free           int64
		fee            *int64
		want           modelTokenPrice
	}{
		{"one input", 1, 0, 1, nil, modelTokenPrice{gross: 1, remainder: 5_000_000}},
		{"one output", 0, 1, 1, nil, modelTokenPrice{gross: 1, remainder: 20_000_000}},
		{"fee before rounding", 1, 0, 1, &fee, modelTokenPrice{gross: 1, remainder: 4_000_000}},
		{"mixed", 1, 1, 1, nil, modelTokenPrice{gross: 101, paid: 100, payout: 100, remainder: 5_000_000}},
		{"mixed with fee", 1, 1, 1, &fee, modelTokenPrice{gross: 101, paid: 100, payout: 80, remainder: 4_000_000}},
		{"paid after exhaustion", 1, 0, 0, nil, modelTokenPrice{gross: 100, paid: 100, payout: 100}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := priceModelTokens(promoTestModel, tt.prompt, tt.output, 50_000, 200_000, true, tt.free, tt.fee)
			if err != nil || got != tt.want {
				t.Fatalf("got %+v %v; want %+v", got, err, tt.want)
			}
		})
	}
	if _, err := priceModelTokens(promoTestModel, math.MaxInt, math.MaxInt, math.MaxInt64, math.MaxInt64, true, 1, nil); err == nil {
		t.Fatal("overflowing price accepted")
	}
}

func TestModelTokenPromotionTinyRequestsCannotAmplifyPayout(t *testing.T) {
	s, st, r := promotionTestServer(t, 100)
	// The first fractional earning commits but loses its acknowledgement.
	// Reconciliation must neither lose nor duplicate that remainder.
	s.store = &promotionSettlementFaultStore{Store: st, ModelTokenPromotionStore: st}
	if err := st.SetModelPrice("platform", promoTestModel, 50_000, 200_000); err != nil {
		t.Fatal(err)
	}
	for i := range 100 {
		w := httptest.NewRecorder()
		_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1})
		if handled {
			t.Fatal(w.Body)
		}
		provider, pr := promotionCompletionRequest(s, modelTokenReservation(r), modelTokenReservation(r).ID)
		s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 1}})
		s.maintainModelTokens(st, time.Now())
		if got := st.GetWithdrawableBalance("paid-provider"); got != int64(i+1)/20 {
			t.Fatalf("after %d requests payout=%d", i+1, got)
		}
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].UsedTokens != 100 || grants[0].ReservedTokens != 0 || st.GetBalance("promotion-user") != 0 {
		t.Fatal("incorrect grant/consumer accounting", grants)
	}
	// A subsequent fully paid request still funds the ordinary 100 micro-USD minimum.
	if err := st.Credit("promotion-user", 100, store.LedgerAdminCredit, "paid-fallback"); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1})
	if handled {
		t.Fatal(w.Body)
	}
	provider, pr := promotionCompletionRequest(s, modelTokenReservation(r), "paid-fallback")
	s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 1}})
	if st.GetBalance("promotion-user") != 0 || st.GetWithdrawableBalance("paid-provider") != 105 {
		t.Fatal("paid minimum changed")
	}
}
