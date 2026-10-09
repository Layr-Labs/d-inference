package payouts_test

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestGlobalFundingQueueRefreshesQuoteAndSendsOnce(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetGlobalPayout(quote.ID)
	if err != nil {
		t.Fatal(err)
	}
	p.ID = "short-lived-quote"
	p.ExpiresAt = time.Now().Add(100 * time.Millisecond)
	if err := st.CreateGlobalPayoutQuote(*p); err != nil {
		t.Fatal(err)
	}
	zero := int64(0)
	f.mu.Lock()
	f.availableUSD = &zero
	f.mu.Unlock()
	body := `{"amount_usd":"10","quote_id":"` + p.ID + `"}`
	for range 2 {
		w = globalAPIRequest(t, s, u, "/withdraw", body, s.HandleStripeWithdraw)
		if w.Code != 202 || !strings.Contains(w.Body.String(), `"status":"queued"`) {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
	}
	if st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatal("reconfirmation debited twice")
	}
	queued, _ := st.GetGlobalPayout(p.ID)
	if strings.Contains(w.Body.String(), `"eta"`) {
		t.Fatal("queued response promised a bank delivery date")
	}
	if queued.DispatchAttempts != 0 || queued.Refunded {
		t.Fatalf("unsafe queue %+v", queued)
	}
	time.Sleep(120 * time.Millisecond)
	f.mu.Lock()
	f.availableUSD = nil
	f.rate = 81
	f.mu.Unlock()
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() { defer wg.Done(); _ = s.syncGlobalPayout(context.Background(), p.ID) }()
	}
	wg.Wait()
	got, _ := st.GetGlobalPayout(p.ID)
	if got.Status != "processing" || got.ExternalID != "obp_gp" || got.DestinationAmount != 81_000 {
		t.Fatalf("expired quote was not refreshed %+v", got)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.creates != 1 || f.quoteCalls != 2 {
		t.Fatalf("creates=%d quotes=%d", f.creates, f.quoteCalls)
	}
	if _, ok := f.payments["gp-withdraw-"+p.ID+"-funding-1"]; !ok {
		t.Fatal("missing persisted retry key")
	}
	if st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatal("worker debited again")
	}
}

func TestGlobalDefinitiveFundingRejectionQueuesButUnknownSendDoesNot(t *testing.T) {
	for _, ambiguous := range []bool{false, true} {
		t.Run(map[bool]string{false: "rejected", true: "unknown"}[ambiguous], func(t *testing.T) {
			s, st, u, f := globalPayoutAPIFixture(t, ambiguous)
			globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
			w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
			var quote struct {
				ID string `json:"id"`
			}
			_ = json.Unmarshal(w.Body.Bytes(), &quote)
			if !ambiguous {
				f.fundingReject = true
			}
			body := `{"amount_usd":"10","quote_id":"` + quote.ID + `"}`
			globalAPIRequest(t, s, u, "/withdraw", body, s.HandleStripeWithdraw)
			if ambiguous {
				f.fundingReject = true
				globalAPIRequest(t, s, u, "/withdraw", body, s.HandleStripeWithdraw)
			}
			got, _ := st.GetGlobalPayout(quote.ID)
			expected := "queued"
			if ambiguous {
				expected = "pending"
			}
			if got.Status != expected || got.Refunded || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
				t.Fatalf("wrong disposition %+v", got)
			}
			if !ambiguous {
				f.fundingReject = false
				if err := s.syncGlobalPayout(context.Background(), quote.ID); err != nil {
					t.Fatal(err)
				}
				got, _ = st.GetGlobalPayout(quote.ID)
				if got.Status != "processing" || got.FundingGeneration != 1 {
					t.Fatalf("queue did not resume %+v", got)
				}
			} else if got.FailureCode != store.WithdrawalFundingReason && got.FundingGeneration != 0 {
				t.Fatal("unknown send changed key")
			}
		})
	}
}

func TestGlobalFundingReadFailureDoesNotConsumeSendAttempt(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil {
		t.Fatal(err)
	}
	f.fundingReadFailures = 1
	body := `{"amount_usd":"10","quote_id":"` + quote.ID + `"}`
	w = globalAPIRequest(t, s, u, "/withdraw", body, s.HandleStripeWithdraw)
	var response map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if _, ok := response["eta"]; ok {
		t.Fatalf("unsent payout promised a bank ETA: %s", w.Body.String())
	}
	if message, ok := response["message"].(string); !ok || !strings.Contains(message, "reserved") {
		t.Fatalf("missing pending reservation message: %s", w.Body.String())
	}
	unsent, _ := st.GetGlobalPayout(quote.ID)
	if unsent.DispatchAttempts != 0 || !unsent.DispatchStartedAt.IsZero() || f.creates != 0 {
		t.Fatalf("failed preflight consumed a send: %+v", unsent)
	}
	zero := int64(0)
	f.availableUSD = &zero
	w = globalAPIRequest(t, s, u, "/withdraw", body, s.HandleStripeWithdraw)
	if !strings.Contains(w.Body.String(), `"status":"queued"`) {
		t.Fatal(w.Body.String())
	}
	f.availableUSD = nil
	if err := s.syncGlobalPayout(context.Background(), quote.ID); err != nil {
		t.Fatal(err)
	}
	sent, _ := st.GetGlobalPayout(quote.ID)
	if sent.Status != "processing" || sent.DispatchAttempts != 1 || sent.DispatchStartedAt.IsZero() || sent.Refunded || f.creates != 1 {
		t.Fatalf("failed preflight stranded withdrawal: %+v", sent)
	}
	if b, wb := st.GetBalanceWithWithdrawable(u.AccountID); b != 10_000_000 || wb != b {
		t.Fatalf("preflight retry moved ledger twice: %d %d", b, wb)
	}
}

func TestGlobalFundingQueueRefundsAnUnsendableRenewedQuote(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil {
		t.Fatal(err)
	}
	p, _ := st.GetGlobalPayout(quote.ID)
	p.ID = "quote-out-of-bounds"
	p.ExpiresAt = time.Now().Add(100 * time.Millisecond)
	if err := st.CreateGlobalPayoutQuote(*p); err != nil {
		t.Fatal(err)
	}
	zero := int64(0)
	f.availableUSD = &zero
	globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+p.ID+`"}`, s.HandleStripeWithdraw)
	time.Sleep(120 * time.Millisecond)
	f.availableUSD = nil
	f.rate = 2_000_000 // The unchanged USD principal now exceeds India's recipient bound.
	for range 2 {
		if err := s.syncGlobalPayout(context.Background(), p.ID); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := st.GetGlobalPayout(p.ID)
	if got.Status != "failed" || !got.Refunded || got.Rejection == nil || got.Rejection.Attempt != 0 || got.FailureCode != "recipient_amount_out_of_bounds" || f.creates != 0 {
		t.Fatalf("unsendable quote remained reserved: %+v", got)
	}
	if b, wb := st.GetBalanceWithWithdrawable(u.AccountID); b != 20_000_000 || wb != b {
		t.Fatalf("quote rejection did not refund exactly once: %d %d", b, wb)
	}
}

func TestGlobalFundingQueueUsesRenewedFeesBeforeCheckingFunding(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil {
		t.Fatal(err)
	}
	p, err := st.GetGlobalPayout(quote.ID)
	if err != nil {
		t.Fatal(err)
	}
	p.ID = "falling-fee-quote"
	p.ExpiresAt = time.Now().Add(100 * time.Millisecond)
	if err := st.CreateGlobalPayoutQuote(*p); err != nil {
		t.Fatal(err)
	}
	available := int64(1010) // Covers $10 principal plus the renewed fee, but not the old $1.50 fee.
	f.mu.Lock()
	f.availableUSD = &available
	f.mu.Unlock()
	w = globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+p.ID+`"}`, s.HandleStripeWithdraw)
	if !strings.Contains(w.Body.String(), `"status":"queued"`) {
		t.Fatal(w.Body.String())
	}
	time.Sleep(120 * time.Millisecond)
	f.mu.Lock()
	f.quoteFeeValue = json.Number("10")
	f.mu.Unlock()
	if err := s.syncGlobalPayout(context.Background(), p.ID); err != nil {
		t.Fatal(err)
	}
	got, err := st.GetGlobalPayout(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "processing" || got.ExternalID != "obp_gp" || got.Refunded {
		t.Fatalf("stale fees stranded a funded payout: %+v", got)
	}
	if f.creates != 1 || f.quoteCalls < 2 {
		t.Fatalf("creates=%d quoteCalls=%d", f.creates, f.quoteCalls)
	}
	if b, wb := st.GetBalanceWithWithdrawable(u.AccountID); b != 10_000_000 || wb != b {
		t.Fatalf("fee refresh debited again: %d %d", b, wb)
	}
}
