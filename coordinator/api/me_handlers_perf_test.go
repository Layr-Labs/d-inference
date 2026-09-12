package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingMeStore counts the store calls the /v1/me handlers make.
type countingMeStore struct {
	store.Store
	windows       atomic.Int64
	listProviders atomic.Int64
	getReputation atomic.Int64
	getReputBatch atomic.Int64
}

func (c *countingMeStore) AccountEarningsWindows(accountID string, now time.Time) (store.AccountEarningsWindows, error) {
	c.windows.Add(1)
	return c.Store.AccountEarningsWindows(accountID, now)
}

func (c *countingMeStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]store.ProviderRecord, error) {
	c.listProviders.Add(1)
	return c.Store.ListProvidersByAccount(ctx, accountID)
}

func (c *countingMeStore) GetReputation(ctx context.Context, providerID string) (*store.ReputationRecord, error) {
	c.getReputation.Add(1)
	return c.Store.GetReputation(ctx, providerID)
}

func (c *countingMeStore) GetReputations(ctx context.Context, ids []string) (map[string]*store.ReputationRecord, error) {
	c.getReputBatch.Add(1)
	return c.Store.GetReputations(ctx, ids)
}

func newMeTestServer(t *testing.T) (*Server, *countingMeStore) {
	t.Helper()
	srv, _ := testServer(t)
	st := &countingMeStore{Store: srv.store}
	srv.store = st
	return srv, st
}

func getMySummary(t *testing.T, srv *Server, accountID string) mySummaryResponse {
	t.Helper()
	w := httptest.NewRecorder()
	srv.handleMySummary(w, reqWithUser(http.MethodGet, "/v1/me/summary", "", accountID))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var resp mySummaryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return resp
}

// TestMySummaryWindowsExactBeyondFiveThousandRows: an account with 6,000
// earnings rows in the last 7 d used to have its 7 d figures summed from a
// 5,000-row page; the aggregate reports all of them.
func TestMySummaryWindowsExactBeyondFiveThousandRows(t *testing.T) {
	srv, st := newMeTestServer(t)
	const account = "acct-6000"
	now := time.Now()
	var want7dMoney, want24hMoney int64
	var want24hJobs int64
	for i := range 6_000 {
		age := time.Duration(i+1) * 7 * 24 * time.Hour / 6_001
		amount := int64(100 + i%5)
		createdAt := now.Add(-age)
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID: account, ProviderID: "node", ProviderKey: "key",
			JobID: fmt.Sprintf("job-%d", i), Model: "model",
			AmountMicroUSD: amount, CreatedAt: createdAt,
		}); err != nil {
			t.Fatal(err)
		}
		want7dMoney += amount
		if createdAt.After(now.Add(-24 * time.Hour)) {
			want24hMoney += amount
			want24hJobs++
		}
	}
	// The page the old implementation summed cannot hold the whole window.
	page, err := st.GetAccountEarnings(account, 5000)
	if err != nil || len(page) != 5000 {
		t.Fatalf("old row page = %d rows, %v; want 5,000 (truncated)", len(page), err)
	}

	resp := getMySummary(t, srv, account)
	if resp.Last7dJobs != 6_000 || resp.Last7dMicroUSD != want7dMoney {
		t.Fatalf("last 7d = %d jobs / %d micro, want 6000 / %d", resp.Last7dJobs, resp.Last7dMicroUSD, want7dMoney)
	}
	if resp.Last24hJobs != want24hJobs || resp.Last24hMicroUSD != want24hMoney {
		t.Fatalf("last 24h = %d jobs / %d micro, want %d / %d", resp.Last24hJobs, resp.Last24hMicroUSD, want24hJobs, want24hMoney)
	}
}

// TestMySummaryWindowsCachedPerAccount: repeated polls within the cache TTL
// compute the windows once per account; a different account gets its own.
func TestMySummaryWindowsCachedPerAccount(t *testing.T) {
	srv, st := newMeTestServer(t)
	for _, account := range []string{"acct-a", "acct-b"} {
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID: account, ProviderID: "node-" + account, ProviderKey: "key-" + account,
			JobID: "job-" + account, Model: "model", AmountMicroUSD: 500, CreatedAt: time.Now(),
		}); err != nil {
			t.Fatal(err)
		}
	}
	for range 3 {
		if resp := getMySummary(t, srv, "acct-a"); resp.Last24hJobs != 1 || resp.Last24hMicroUSD != 500 {
			t.Fatalf("acct-a summary = %+v", resp)
		}
	}
	if got := st.windows.Load(); got != 1 {
		t.Fatalf("window aggregates for 3 polls of one account = %d, want 1 (cached %s)", got, mySummaryWindowsCacheTTL)
	}
	if resp := getMySummary(t, srv, "acct-b"); resp.Last24hJobs != 1 {
		t.Fatalf("acct-b summary = %+v", resp)
	}
	if got := st.windows.Load(); got != 2 {
		t.Fatalf("window aggregates after a second account = %d, want 2 (per-account entries)", got)
	}
}

// TestMyProvidersBatchesReputationLookups: a fleet of 20 stored machines is
// served with exactly one provider list and one batched reputation lookup —
// never a reputation read per machine.
func TestMyProvidersBatchesReputationLookups(t *testing.T) {
	srv, st := newMeTestServer(t)
	const account = "acct-fleet"
	ctx := context.Background()
	for i := range 20 {
		id := fmt.Sprintf("machine-%02d", i)
		if err := st.UpsertProvider(ctx, store.ProviderRecord{
			ID: id, AccountID: account, Backend: "mlx-swift",
			Hardware: json.RawMessage(`{"chip_name":"Apple M4 Max","memory_gb":64}`),
			Models:   json.RawMessage(`[]`),
			LastSeen: time.Now().Add(-time.Duration(i) * time.Minute),
		}); err != nil {
			t.Fatalf("upsert provider: %v", err)
		}
		if err := st.UpsertReputation(ctx, id, store.ReputationRecord{
			TotalJobs: 10 + i, SuccessfulJobs: 10 + i, ChallengesPassed: 3,
		}); err != nil {
			t.Fatalf("upsert reputation: %v", err)
		}
	}

	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", account))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Providers) != 20 {
		t.Fatalf("providers = %d, want 20", len(resp.Providers))
	}
	for _, p := range resp.Providers {
		if p.Reputation.TotalJobs < 10 || p.Reputation.ChallengesPassed != 3 {
			t.Fatalf("provider %s reputation not attached: %+v", p.ID, p.Reputation)
		}
	}
	if list, batch, single := st.listProviders.Load(), st.getReputBatch.Load(), st.getReputation.Load(); list != 1 || batch != 1 || single != 0 {
		t.Fatalf("store calls: ListProvidersByAccount=%d GetReputations=%d GetReputation=%d, want 1/1/0", list, batch, single)
	}
}
