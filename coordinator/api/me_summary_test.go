package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMySummaryAggregatesBeyondHistoryLimit(t *testing.T) {
	srv, st := testServer(t)
	const accountID = "acct-summary-window"
	now := time.Now()

	// The old handler loaded only the newest 5,000 rows before calculating its
	// windows. Put 5,001 inference rows in the last 24 hours so that regression
	// would undercount both dashboard windows.
	for i := 0; i < 5001; i++ {
		earning := &store.ProviderEarning{
			AccountID:      accountID,
			ProviderID:     "provider-1",
			ProviderKey:    "provider-key-1",
			JobID:          "job-" + string(rune(i)),
			Model:          "qwen",
			AmountMicroUSD: 1,
			CreatedAt:      now.Add(-time.Hour),
		}
		if err := st.RecordProviderEarning(earning); err != nil {
			t.Fatalf("RecordProviderEarning(%d): %v", i, err)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/me/summary", nil)
	req = withPrivyUser(req, &store.User{AccountID: accountID})
	w := httptest.NewRecorder()
	srv.handleMySummary(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var response mySummaryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode summary: %v", err)
	}

	if response.Last24hJobs != 5001 || response.Last7dJobs != 5001 {
		t.Fatalf("jobs = (%d, %d), want (5001, 5001)", response.Last24hJobs, response.Last7dJobs)
	}
	if response.Last24hMicroUSD != 5001 || response.Last7dMicroUSD != 5001 {
		t.Fatalf("money = (%d, %d), want (5001, 5001)", response.Last24hMicroUSD, response.Last7dMicroUSD)
	}
}
