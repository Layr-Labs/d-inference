package api

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAccountEarningsEmailBelongsToAuthenticatedOwner(t *testing.T) {
	for _, prefix := range []string{"eigeninference-pt-", desktopAccountTokenPrefix} {
		t.Run(prefix, func(t *testing.T) {
			srv, st := deviceTestServer()
			for i, owner := range []string{"alice", "bob"} {
				if err := st.CreateUser(&store.User{AccountID: owner, PrivyUserID: "did:privy:" + owner, Email: owner + "@example.com"}); err != nil {
					t.Fatal(err)
				}
				token := prefix + strings.Repeat(string(rune('a'+i)), 64)
				if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: sha256Hash(token), AccountID: owner, Active: true, Label: desktopAccountCodePrefix + "TEST", CreatedAt: time.Now()}); err != nil {
					t.Fatal(err)
				}
				// Query parameters must never select another person's identity, including cached reads.
				for range 2 {
					req := httptest.NewRequest("GET", "/v1/provider/account-earnings?account_id=someone-else", nil)
					req.Header.Set("Authorization", "Bearer "+token)
					w := httptest.NewRecorder()
					srv.Handler().ServeHTTP(w, req)
					var body struct {
						Email     string `json:"email"`
						AccountID string `json:"account_id"`
					}
					if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || w.Code != 200 || body.Email != owner+"@example.com" || body.AccountID != owner {
						t.Fatalf("incorrect identity: status=%d body=%s", w.Code, w.Body)
					}
				}
			}
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/provider/account-earnings", nil))
			if w.Code != 401 || strings.Contains(w.Body.String(), "@example.com") {
				t.Fatal("unauthenticated email disclosure")
			}
		})
	}
}
