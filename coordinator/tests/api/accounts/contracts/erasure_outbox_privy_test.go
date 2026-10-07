package accounts_test

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// The scrub replaces users.privy_user_id, so the privy_user row keeps the
// original ID until Privy confirms the deletion. Stripe mock mode does not
// skip it, and no error or status answer shows the ID.
func TestErasureOutboxDeletesPrivyUser(t *testing.T) {
	for _, tc := range []struct {
		name      string
		configure func(*testkit.PrivyUsers)
		done      bool
	}{
		{name: "deleted", configure: func(p *testkit.PrivyUsers) { p.SetStatus(http.StatusNoContent) }, done: true},
		{name: "already gone", configure: func(p *testkit.PrivyUsers) { p.SetStatus(http.StatusNotFound) }, done: true},
		{name: "server error", configure: func(p *testkit.PrivyUsers) { p.SetStatus(http.StatusInternalServerError) }},
		{name: "unauthorized", configure: func(p *testkit.PrivyUsers) { p.SetStatus(http.StatusUnauthorized) }},
		{name: "transport error", configure: func(p *testkit.PrivyUsers) { p.SetTransportError(errors.New("connection reset")) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fx := newOutboxFixture(t, true)
			privy := testkit.NewPrivyUsers(t, fx.srv, fx.st)
			tc.configure(privy)
			account := fx.scrub(t, outboxSeed{})
			did := "did:privy:" + account
			if before := fx.row(t, account, store.ErasureTargetPrivyUser); before.ExternalID != did || before.State != store.ErasureOutboxPending {
				t.Fatalf("scrub did not queue the original Privy user ID: %+v", before)
			}
			fx.pass(t, account)
			if got := privy.Deleted(); len(got) != 1 || got[0] != did {
				t.Fatalf("Privy delete requests = %v; want [%s]", got, did)
			}
			row := fx.row(t, account, store.ErasureTargetPrivyUser)
			if tc.done {
				wantDone(t, row)
			} else {
				wantRetry(t, row, 1)
			}
			if strings.Contains(row.LastError, did) {
				t.Fatalf("last_error shows the Privy user ID: %q", row.LastError)
			}
			assertStatusHidesPrivyUserID(t, fx, account, did)
		})
	}
}

func TestErasureOutboxRetriesPrivyUserWithoutPrivy(t *testing.T) {
	fx := newOutboxFixture(t, true)
	account := fx.scrub(t, outboxSeed{})
	fx.pass(t, account)
	row := fx.row(t, account, store.ErasureTargetPrivyUser)
	wantRetry(t, row, 1)
	if row.LastError != "Privy is not configured" || row.ExternalID != "did:privy:"+account {
		t.Fatalf("row without Privy = %+v", row)
	}
}

func assertStatusHidesPrivyUserID(t *testing.T, fx *outboxFixture, account, did string) {
	t.Helper()
	ts := httptest.NewServer(fx.srv.Handler())
	t.Cleanup(ts.Close)
	req, err := http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/accounts/"+account+"/erasure", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer admin-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), string(store.ErasureTargetPrivyUser)) {
		t.Fatalf("status = %d %s", resp.StatusCode, body)
	}
	if strings.Contains(string(body), did) {
		t.Fatalf("status answer shows the Privy user ID: %s", body)
	}
}
