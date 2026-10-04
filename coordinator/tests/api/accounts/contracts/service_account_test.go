package accounts_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAdminSetUserRole(t *testing.T) {
	srv, st := newKeyTestServer(t)
	srv.SetAdminKey("admin-key")
	if err := st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"}); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/role", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// Grant service role.
	if rec := call(`{"account_id":"acct-or","role":"service"}`); rec.Code != http.StatusOK {
		t.Fatalf("grant role status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ := st.GetUserByAccountID("acct-or")
	if u.Role != store.RoleService {
		t.Errorf("role = %q, want service", u.Role)
	}

	// Invalid role rejected.
	if rec := call(`{"account_id":"acct-or","role":"superadmin"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("invalid role status = %d, want 400", rec.Code)
	}

	// Missing account_id rejected.
	if rec := call(`{"role":"service"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("missing account status = %d, want 400", rec.Code)
	}

	// Unknown user → 404.
	if rec := call(`{"account_id":"ghost","role":"service"}`); rec.Code != http.StatusNotFound {
		t.Errorf("unknown user status = %d, want 404", rec.Code)
	}
}

func TestAdminSetUserRoleRequiresAdmin(t *testing.T) {
	srv, st := newKeyTestServer(t)
	srv.SetAdminKey("admin-key")
	_ = st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"})

	req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/role", strings.NewReader(`{"account_id":"acct-or","role":"service"}`))
	req.Header.Set("Authorization", "Bearer wrong-key")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Errorf("non-admin got %d, want non-200", rec.Code)
	}
}

func TestAdminSetUserPlatformFee(t *testing.T) {
	srv, st := newKeyTestServer(t)
	srv.SetAdminKey("admin-key")
	if err := st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"}); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/platform-fee", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// Waive the fee (0%).
	if rec := call(`{"account_id":"acct-or","platform_fee_percent":0}`); rec.Code != http.StatusOK {
		t.Fatalf("set 0%% status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ := st.GetUserByAccountID("acct-or")
	if u.PlatformFeePercent == nil || *u.PlatformFeePercent != 0 {
		t.Errorf("fee override = %v, want 0", u.PlatformFeePercent)
	}

	// Clear override (omitted field → nil).
	if rec := call(`{"account_id":"acct-or"}`); rec.Code != http.StatusOK {
		t.Fatalf("clear status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ = st.GetUserByAccountID("acct-or")
	if u.PlatformFeePercent != nil {
		t.Errorf("fee after clear = %v, want nil", *u.PlatformFeePercent)
	}

	// Out-of-range rejected.
	if rec := call(`{"account_id":"acct-or","platform_fee_percent":150}`); rec.Code != http.StatusBadRequest {
		t.Errorf("out-of-range status = %d, want 400", rec.Code)
	}

	// Response shape for a set value.
	rec := call(`{"account_id":"acct-or","platform_fee_percent":3}`)
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["status"] != "platform_fee_updated" {
		t.Errorf("status field = %v", resp["status"])
	}
}
