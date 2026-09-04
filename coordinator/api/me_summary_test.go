package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// /v1/me/summary window totals come from one aggregate, so an account with
// more rows than the old 5,000-row page is summed exactly. (The memory store's
// GetAccountEarnings truncates at the limit just like Postgres, so this fails
// on the page-and-sum handler.)
func TestMySummaryWindowTotalsExactBeyondPageLimit(t *testing.T) {
	srv, st := newKeyTestServer(t)
	now := time.Now()
	seed := func(n int, tag string, at time.Time, amount int64) {
		for i := 0; i < n; i++ {
			if err := st.RecordProviderEarning(&store.ProviderEarning{
				AccountID: "acct-1", ProviderKey: "pk", JobID: fmt.Sprintf("%s-%d", tag, i), Model: "m",
				AmountMicroUSD: amount, CreatedAt: at,
			}); err != nil {
				t.Fatal(err)
			}
		}
	}
	seed(5001, "h", now.Add(-time.Hour), 2)
	seed(10, "d", now.Add(-3*24*time.Hour), 5)
	seed(3, "old", now.Add(-10*24*time.Hour), 1000)

	w := httptest.NewRecorder()
	srv.handleMySummary(w, reqWithUser(http.MethodGet, "/v1/me/summary", "", "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var resp mySummaryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Last24hJobs != 5001 || resp.Last24hMicroUSD != 2*5001 {
		t.Fatalf("last 24h = %d jobs / %d µUSD, want 5001 / %d", resp.Last24hJobs, resp.Last24hMicroUSD, 2*5001)
	}
	if resp.Last7dJobs != 5011 || resp.Last7dMicroUSD != 2*5001+50 {
		t.Fatalf("last 7d = %d jobs / %d µUSD, want 5011 / %d", resp.Last7dJobs, resp.Last7dMicroUSD, 2*5001+50)
	}
	if resp.LifetimeJobs != 5014 {
		t.Fatalf("lifetime jobs = %d, want 5014", resp.LifetimeJobs)
	}
}

// reputationCountingStore forwards to the real memory store and counts the
// per-provider and batched reputation reads.
type reputationCountingStore struct {
	store.Store
	single atomic.Int64
	batch  atomic.Int64
}

func (c *reputationCountingStore) GetReputation(ctx context.Context, providerID string) (*store.ReputationRecord, error) {
	c.single.Add(1)
	return c.Store.GetReputation(ctx, providerID)
}

func (c *reputationCountingStore) GetReputations(ctx context.Context, ids []string) (map[string]store.ReputationRecord, error) {
	c.batch.Add(1)
	return c.Store.GetReputations(ctx, ids)
}

// /v1/me/providers attaches stored reputation for a 20-machine fleet with one
// batched read instead of one read per machine.
func TestMyProvidersBatchesReputationReads(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mem := store.NewMemory(store.Config{})
	st := &reputationCountingStore{Store: mem}
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fleetSize = 20
	for i := 0; i < fleetSize; i++ {
		id := fmt.Sprintf("machine-%02d", i)
		if err := mem.UpsertProvider(context.Background(), store.ProviderRecord{ID: id, SerialNumber: "SER-" + id, AccountID: "acct-1", LastSeen: time.Now()}); err != nil {
			t.Fatal(err)
		}
		if err := mem.UpsertReputation(context.Background(), id, store.ReputationRecord{TotalJobs: i + 1, SuccessfulJobs: i + 1, ChallengesPassed: 1}); err != nil {
			t.Fatal(err)
		}
	}

	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var resp myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Providers) != fleetSize {
		t.Fatalf("providers = %d, want %d", len(resp.Providers), fleetSize)
	}
	for _, mp := range resp.Providers {
		var idx int
		if _, err := fmt.Sscanf(mp.ID, "machine-%02d", &idx); err != nil {
			t.Fatalf("unexpected provider id %q", mp.ID)
		}
		if mp.Reputation.TotalJobs != idx+1 || mp.Reputation.ChallengesPassed != 1 {
			t.Fatalf("provider %s reputation = %+v, want stored record", mp.ID, mp.Reputation)
		}
	}
	if st.single.Load() != 0 || st.batch.Load() != 1 {
		t.Fatalf("reputation reads: %d per-provider, %d batched; want 0 and 1", st.single.Load(), st.batch.Load())
	}
}
