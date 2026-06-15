package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// failingListProvidersStore wraps a store and fails ListProvidersByAccount, to
// simulate a DB outage during the offline-ownership branch of node-earnings.
type failingListProvidersStore struct {
	store.Store
}

func (failingListProvidersStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]store.ProviderRecord, error) {
	return nil, fmt.Errorf("simulated store outage")
}

// TestNodeEarningsSummaryScopedToOwnerAfterRelink verifies the node-earnings
// lifetime summary is scoped to the calling account. The X25519 provider key is
// stable across re-links, so a machine that earned under a prior owner must not
// leak that owner's aggregate revenue to the current owner — only the per-job
// rows were scoped before; the total/count must be too.
func TestNodeEarningsSummaryScopedToOwnerAfterRelink(t *testing.T) {
	srv, st := testWithdrawServer(t)

	// Same machine (stable X25519 key) earned under a prior owner, then was
	// re-linked to the current owner. seedNodeEarning's UpsertProvider overwrites
	// the record's owner, so the record now belongs to acct-current.
	const key = "key-relinked"
	seedNodeEarning(t, st, "acct-prior", key, "job-prior", 900_000)
	seedNodeEarning(t, st, "acct-current", key, "job-current", 100_000)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key="+key, nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-current"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp nodeEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	// Current owner must see ONLY their own node total/count, never the combined
	// 1_000_000 / 2 across the prior owner.
	if resp.TotalMicroUSD != 100_000 || resp.Count != 1 {
		t.Fatalf("summary = %d/%d, want 100000/1 (scoped to current owner)", resp.TotalMicroUSD, resp.Count)
	}
	if body := w.Body.String(); strings.Contains(body, "900000") || strings.Contains(body, "1000000") {
		t.Fatalf("summary leaked the prior owner's aggregate revenue: %s", body)
	}
}

// TestAttachEarningsScopedToAccountAfterRelink is the dashboard-card counterpart:
// attachEarnings stamps per-machine totals on each card, and must scope the
// summary to the card's account so a re-linked machine never folds in a prior
// owner's earnings.
func TestAttachEarningsScopedToAccountAfterRelink(t *testing.T) {
	srv, st := testWithdrawServer(t)

	const key = "key-card-relinked"
	seedNodeEarning(t, st, "acct-prior", key, "job-prior", 900_000)
	seedNodeEarning(t, st, "acct-current", key, "job-current", 100_000)

	mp := &myProvider{AccountID: "acct-current", ProviderKey: key}
	srv.attachEarnings(mp)

	if mp.EarningsTotalMicroUSD != 100_000 || mp.EarningsCount != 1 {
		t.Fatalf("card earnings = %d/%d, want 100000/1 (scoped to current owner, not the 1000000/2 combined)",
			mp.EarningsTotalMicroUSD, mp.EarningsCount)
	}
}

// TestNodeEarningsStoreErrorReturns500NotForbidden verifies that a store failure
// during the offline-ownership lookup surfaces as 500, not a false 403. Returning
// 403 on a DB outage would deny a legitimate owner as though the node belonged to
// someone else.
func TestNodeEarningsStoreErrorReturns500NotForbidden(t *testing.T) {
	srv, st := testWithdrawServer(t)
	// No live provider with this key in the registry, so ownership falls through
	// to ListProvidersByAccount — which now fails.
	srv.store = failingListProvidersStore{Store: st}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=key-offline", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-A"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 (store outage must not be reported as 403): %s", w.Code, w.Body.String())
	}
}

// TestNodeEarningsOwnerRowsNotCrowdedOutByRelink verifies the per-job earnings
// list is scoped to the caller in the store query, BEFORE the limit. A machine
// re-linked from a prior owner shares the key; if the prior owner holds the
// newest rows, a key-only fetch then in-memory filter could hand the caller an
// empty list within the limit window even though they have earnings.
func TestNodeEarningsOwnerRowsNotCrowdedOutByRelink(t *testing.T) {
	srv, st := testWithdrawServer(t)

	const key = "key-crowded"
	// Current owner earned first (older row) and owns the machine record.
	seedNodeEarning(t, st, "acct-current", key, "job-own", 100_000)
	// Prior owner has a NEWER earnings row under the same key, recorded directly
	// so it does not change the machine's owner record.
	if err := st.RecordProviderEarning(&store.ProviderEarning{
		AccountID: "acct-prior", ProviderKey: key, JobID: "job-prior",
		Model: "m", AmountMicroUSD: 900_000, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("record prior earning: %v", err)
	}

	// limit=1: a key-only fetch would return the prior owner's newest row and
	// then filter it out, leaving the owner an empty list. The account-scoped
	// query must still return the owner's own row.
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key="+key+"&limit=1", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-current"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp nodeEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.RecentCount != 1 || len(resp.Earnings) != 1 {
		t.Fatalf("owner got %d recent rows, want 1 (own row crowded out by relink)", len(resp.Earnings))
	}
	if resp.Earnings[0].AccountID != "acct-current" {
		t.Fatalf("returned another account's row: account_id=%s", resp.Earnings[0].AccountID)
	}
	if strings.Contains(w.Body.String(), "900000") {
		t.Fatalf("leaked the prior owner's row: %s", w.Body.String())
	}
}

// TestGetProviderEarningsForAccountScopesRows is the store-level unit: only rows
// matching BOTH key AND account are returned, with the account filter applied
// before the limit.
func TestGetProviderEarningsForAccountScopesRows(t *testing.T) {
	st := store.NewMemory(store.Config{})

	const key = "key-rows"
	for _, e := range []store.ProviderEarning{
		{AccountID: "acct-A", ProviderKey: key, JobID: "a1", AmountMicroUSD: 100_000},
		{AccountID: "acct-B", ProviderKey: key, JobID: "b1", AmountMicroUSD: 900_000}, // newer, other account
		{AccountID: "acct-A", ProviderKey: "other", JobID: "a2", AmountMicroUSD: 50_000},
	} {
		e := e
		if err := st.RecordProviderEarning(&e); err != nil {
			t.Fatalf("record: %v", err)
		}
	}

	// limit=1 as acct-A: must return acct-A's row for this key, not acct-B's newer one.
	rows, err := st.GetProviderEarningsForAccount(key, "acct-A", 1)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 1 || rows[0].AccountID != "acct-A" || rows[0].JobID != "a1" {
		t.Fatalf("got %+v, want exactly acct-A's a1 row", rows)
	}
}

// TestGetProviderEarningsSummaryForAccountScopesByBothKeys is the store-level
// unit for the new method: only rows matching BOTH provider key AND account are
// aggregated.
func TestGetProviderEarningsSummaryForAccountScopesByBothKeys(t *testing.T) {
	st := store.NewMemory(store.Config{})

	const key = "key-shared"
	for _, e := range []store.ProviderEarning{
		{AccountID: "acct-A", ProviderKey: key, JobID: "a1", AmountMicroUSD: 500_000, PromptTokens: 10, CompletionTokens: 20},
		{AccountID: "acct-A", ProviderKey: key, JobID: "a2", AmountMicroUSD: 250_000, PromptTokens: 5, CompletionTokens: 7},
		{AccountID: "acct-B", ProviderKey: key, JobID: "b1", AmountMicroUSD: 999_000, PromptTokens: 99, CompletionTokens: 99},
		{AccountID: "acct-A", ProviderKey: "other-key", JobID: "a3", AmountMicroUSD: 111_000},
	} {
		e := e
		if err := st.RecordProviderEarning(&e); err != nil {
			t.Fatalf("record earning: %v", err)
		}
	}

	got, err := st.GetProviderEarningsSummaryForAccount(key, "acct-A")
	if err != nil {
		t.Fatalf("summary: %v", err)
	}
	if got.TotalMicroUSD != 750_000 || got.Count != 2 {
		t.Fatalf("acct-A summary = %d/%d, want 750000/2 (excludes acct-B's 999000 and the other-key row)",
			got.TotalMicroUSD, got.Count)
	}
	if got.PromptTokens != 15 || got.CompletionTokens != 27 {
		t.Fatalf("acct-A tokens = %d/%d, want 15/27", got.PromptTokens, got.CompletionTokens)
	}

	// Empty inputs are safe no-ops.
	if s, _ := st.GetProviderEarningsSummaryForAccount("", "acct-A"); s.Count != 0 {
		t.Fatalf("empty key should yield zero summary, got %+v", s)
	}
}
