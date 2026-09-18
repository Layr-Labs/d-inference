package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/trial"
	"nhooyr.io/websocket"
)

// These tests exercise the real JWT verifier, HTTP handler, encrypted provider
// dispatch and terminal settlement; no client-auth context is forged.
func TestBonsaiTrialSessionHTTPPaysProviderWithoutConsumerFunds(t *testing.T) {
	for _, streaming := range []bool{false, true} {
		t.Run(fmt.Sprint(streaming), func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			user := seedUser(t, st, "trial-browser", "trial@example.test")
			token := privySession(t, s, st, user)
			ts := httptest.NewServer(s.Handler())
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, s.registry, trial.BonsaiBuildID)
			defer conn.Close(websocket.StatusNormalClosure, "")
			p := s.registry.GetProvider(providerID)
			p.Mu().Lock()
			p.AccountID = "trial-provider"
			p.Mu().Unlock()
			usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
			done := serveOneInference(ctx, t, conn, pubKey, usage)
			status, body := postTrialChat(t, ctx, ts.URL, token, streaming)
			if status != http.StatusOK {
				t.Fatalf("status=%d body=%s", status, body)
			}
			<-done
			allowance, err := st.GetTrialAllowance(ctx, user.AccountID, trial.DefaultCampaignID)
			if err != nil || allowance.UsedTokens != 150 || allowance.ReservedTokens != 0 {
				t.Fatalf("allowance=%+v err=%v", allowance, err)
			}
			if got := st.GetBalance(user.AccountID); got != 0 {
				t.Fatalf("consumer balance=%d", got)
			}
			cost, _ := s.bonsaiTrial.Rates.Cost(100, 50)
			if got := st.GetWithdrawableBalance("trial-provider"); got != cost {
				t.Fatalf("provider withdrawable=%d want=%d", got, cost)
			}
			rows := st.UsageByConsumer(user.AccountID)
			if len(rows) != 1 || rows[0].CostMicroUSD != 0 {
				t.Fatalf("consumer usage=%+v", rows)
			}
			// The same user cannot turn a paid API key into a free session request.
			key, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{Name: "explicit paid"})
			if err != nil {
				t.Fatal(err)
			}
			status, body = postTrialChat(t, ctx, ts.URL, key, streaming)
			if status != http.StatusPaymentRequired || strings.Contains(body, trial.ExhaustedCode) {
				t.Fatalf("paid key status=%d body=%s", status, body)
			}
			after, _ := st.GetTrialAllowance(ctx, user.AccountID, trial.DefaultCampaignID)
			if after != allowance {
				t.Fatalf("paid key changed quota: before=%+v after=%+v", allowance, after)
			}
		})
	}
}

func TestBonsaiTrialHTTPExhaustionAndDisabledNeverCharge(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			s.bonsaiTrial.Enabled = enabled
			user := seedUser(t, st, "funded-browser", "funded@example.test")
			token := privySession(t, s, st, user)
			if err := st.Credit(user.AccountID, 1_000_000, store.LedgerDeposit, "test"); err != nil {
				t.Fatal(err)
			}
			s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: trial.BonsaiBuildID}})
			if enabled {
				ctx := context.Background()
				_, err := st.ReserveTrial(ctx, store.TrialReservation{ID: "seed-exhausted", AccountID: user.AccountID, CampaignID: trial.DefaultCampaignID, Model: trial.BonsaiBuildID, LimitTokens: trial.DefaultTokenLimit, ReservedTokens: trial.DefaultTokenLimit})
				if err != nil {
					t.Fatal(err)
				}
				if err := st.MarkTrialDispatched(ctx, "seed-exhausted"); err != nil {
					t.Fatal(err)
				}
				if err := st.SettleTrial(ctx, "seed-exhausted", store.TrialSettlement{Usage: store.UsageRecord{ConsumerKey: user.AccountID, RequestID: "seed-exhausted", Model: trial.BonsaiBuildID, PromptTokens: int(trial.DefaultTokenLimit)}}); err != nil {
					t.Fatal(err)
				}
			}
			// Prefer a linked provider to reach quota admission without needing it
			// to generate; exhaustion must terminate before any inference dispatch.
			ts := httptest.NewServer(s.Handler())
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			conn, providerID, _ := setupProviderForBilling(t, ctx, ts, s.registry, trial.BonsaiBuildID)
			defer conn.Close(websocket.StatusNormalClosure, "")
			p := s.registry.GetProvider(providerID)
			p.Mu().Lock()
			p.AccountID = "provider"
			p.Mu().Unlock()
			status, body := postTrialChat(t, ctx, ts.URL, token, true)
			wantStatus, wantCode := http.StatusServiceUnavailable, trial.UnavailableCode
			if enabled {
				wantStatus, wantCode = http.StatusPaymentRequired, trial.ExhaustedCode
			}
			if status != wantStatus || !strings.Contains(body, wantCode) {
				t.Fatalf("status=%d body=%s", status, body)
			}
			if enabled && !strings.Contains(body, trial.ExhaustedMessage) {
				t.Fatalf("exhausted message lost: %s", body)
			}
			if got := st.GetBalance(user.AccountID); got != 1_000_000 {
				t.Fatalf("consumer charged: %d", got)
			}
		})
	}
}

func postTrialChat(t *testing.T, ctx context.Context, base, credential string, stream bool) (int, string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"model": trial.BonsaiBuildID, "messages": []map[string]string{{"role": "user", "content": "hello"}}, "max_tokens": 128, "stream": stream})
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, base+trial.ChatEndpoint, strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	r.Header.Set("Authorization", "Bearer "+credential)
	r.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, string(data)
}
