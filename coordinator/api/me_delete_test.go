package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// seedProviderRecord persists a provider record for the delete tests.
func seedProviderRecord(t *testing.T, st *store.MemoryStore, id, serial, accountID string) {
	t.Helper()
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:           id,
		SerialNumber: serial,
		AccountID:    accountID,
		LastSeen:     time.Now(),
	}); err != nil {
		t.Fatalf("seed provider record: %v", err)
	}
}

type deleteProviderResp struct {
	Deleted     bool   `json:"deleted"`
	Serial      string `json:"serial"`
	RowsRemoved int    `json:"rows_removed"`
}

func TestDeleteMyProvider_OwnerSucceeds(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "p1", "SER-1", "acct-1")

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/SER-1", "", "acct-1")
	r.SetPathValue("serial", "SER-1")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp deleteProviderResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !resp.Deleted || resp.RowsRemoved != 1 {
		t.Fatalf("resp = %+v, want deleted=true rows_removed=1", resp)
	}

	if rec, _ := st.GetProviderBySerial(context.Background(), "SER-1"); rec != nil {
		t.Fatal("record still present after delete")
	}
	recs, _ := st.ListProvidersByAccount(context.Background(), "acct-1")
	if len(recs) != 0 {
		t.Fatalf("account still has %d records after delete", len(recs))
	}
}

func TestDeleteMyProvider_CrossAccount403(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "p1", "SER-1", "acct-1")

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/SER-1", "", "acct-2")
	r.SetPathValue("serial", "SER-1")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", w.Code, w.Body.String())
	}
	if rec, _ := st.GetProviderBySerial(context.Background(), "SER-1"); rec == nil {
		t.Fatal("record was deleted by a non-owner")
	}
}

func TestDeleteMyProvider_Anon401(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "p1", "SER-1", "acct-1")

	r := httptest.NewRequest(http.MethodDelete, "/v1/me/providers/SER-1", nil)
	r.SetPathValue("serial", "SER-1")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401: %s", w.Code, w.Body.String())
	}
}

func TestDeleteMyProvider_NotFound404(t *testing.T) {
	srv, _ := newKeyTestServer(t)

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/NOPE", "", "acct-1")
	r.SetPathValue("serial", "NOPE")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404: %s", w.Code, w.Body.String())
	}
}

func TestDeleteMyProvider_OnlineConflict409(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "live-p", "SER-ON", "acct-1")

	// Register a live provider connection with a matching serial.
	live := srv.registry.Register("live-p", nil, &protocol.RegisterMessage{})
	live.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SER-ON"})
	live.Mu().Lock()
	live.AccountID = "acct-1"
	live.Mu().Unlock()

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/SER-ON", "", "acct-1")
	r.SetPathValue("serial", "SER-ON")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409: %s", w.Code, w.Body.String())
	}
	if rec, _ := st.GetProviderBySerial(context.Background(), "SER-ON"); rec == nil {
		t.Fatal("online machine record was deleted despite 409")
	}
}

func TestDeleteMyProvider_TransferredLiveProviderIsNotDisconnected(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "stale-owner-session", "SER-XFER", "acct-old")
	seedProviderRecord(t, st, "new-owner-session", "SER-XFER", "acct-new")

	live := srv.registry.RegisterAuthenticated(
		"new-owner-live",
		nil,
		&protocol.RegisterMessage{},
		registry.ProviderAuthBinding{
			AccountID: "acct-new",
			TokenHash: sha256Hash("new-owner-token"),
		},
	)
	live.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SER-XFER"})

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/SER-XFER", "", "acct-old")
	r.SetPathValue("serial", "SER-XFER")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	if got := srv.registry.GetProvider(live.ID); got != live {
		t.Fatal("transferred provider's new-owner connection was disconnected")
	}
	if records, err := st.ListProvidersByAccount(context.Background(), "acct-old"); err != nil {
		t.Fatalf("list old owner: %v", err)
	} else if len(records) != 0 {
		t.Fatalf("old owner records = %d, want 0", len(records))
	}
	if records, err := st.ListProvidersByAccount(context.Background(), "acct-new"); err != nil {
		t.Fatalf("list new owner: %v", err)
	} else if len(records) == 0 {
		t.Fatal("new owner's persisted record was deleted")
	}
}

// TestDeleteMyProvider_MultiRowSameSerial verifies all rows sharing a serial
// (one per reconnect session) are removed in a single call.
func TestDeleteMyProvider_MultiRowSameSerial(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "a", "SER-D", "acct-1")
	seedProviderRecord(t, st, "b", "SER-D", "acct-1")

	r := reqWithUser(http.MethodDelete, "/v1/me/providers/SER-D", "", "acct-1")
	r.SetPathValue("serial", "SER-D")
	w := httptest.NewRecorder()
	srv.handleDeleteMyProvider(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp deleteProviderResp
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.RowsRemoved != 2 {
		t.Fatalf("rows_removed = %d, want 2", resp.RowsRemoved)
	}
}

// TestDeleteMyProvider_RouteWiring exercises the real HTTP path through
// srv.Handler() to catch routing/middleware mistakes (Go 1.22+ method+pattern
// precedence vs the literal GET /v1/me/providers route).
func TestDeleteMyProvider_RouteWiring(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "p1", "SER-W", "acct-1")

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Unauthenticated request (no Privy token) — requirePrivyAuth must reject it
	// without ever reaching the handler. We assert the route resolves to a
	// non-404, non-405 status (auth rejection), proving the DELETE pattern is
	// registered and distinct from GET /v1/me/providers.
	req, err := http.NewRequest(http.MethodDelete, ts.URL+"/v1/me/providers/SER-W", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusMethodNotAllowed {
		t.Fatalf("DELETE route not wired: status = %d", resp.StatusCode)
	}
}
