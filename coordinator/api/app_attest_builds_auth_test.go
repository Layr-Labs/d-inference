package api

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Exercise the real mux and real ES256 JWT validation, not an injected user
// context: a missing requireAuth wrapper must break all three operator routes.
func TestAppAttestBuildRoutesAuthenticatePrivyAdminAndRecordActor(t *testing.T) {
	s, st, build := qualificationReleaseFixture(t)
	user := seedUser(t, st, "qualification-operator", "operator@example.com")
	s.SetAdminEmails([]string{user.Email})
	token := privySession(t, s, st, user)
	for _, path := range []string{"/v1/admin/app-attest/builds", "/v1/admin/app-attest/builds/revoke"} {
		var body any = qualificationBody(build)
		if strings.HasSuffix(path, "/revoke") {
			body = map[string]string{"binary_hash": build.Release.BinaryHash, "reason": "operator withdrawal"}
		}
		if w := qualificationCall(t, s, http.MethodPost, path, token, body); w.Code != http.StatusOK {
			t.Fatalf("Privy admin %s: %d %s", path, w.Code, w.Body)
		}
		w := qualificationCall(t, s, http.MethodGet, "/v1/admin/app-attest/builds", token, nil)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), user.AccountID) {
			t.Fatalf("Privy admin inventory: %d %s", w.Code, w.Body)
		}
	}
	rows, err := st.ListAppAttestBuildQualifications(context.Background())
	if err != nil || len(rows) != 1 || rows[0].ApprovedBy != user.AccountID || rows[0].RevokedBy != user.AccountID {
		t.Fatalf("lost authenticated audit attribution: %+v %v", rows, err)
	}
}

func TestAppAttestBuildRoutesRejectNonInteractiveAndNonAdminCredentials(t *testing.T) {
	for _, kind := range []string{"non_admin_session", "invalid_session", "admin_inference_key", "admin_provider_token", "release_key", "missing"} {
		t.Run(kind, func(t *testing.T) {
			s, st, build := qualificationReleaseFixture(t)
			user := seedUser(t, st, "qualification-account", "operator@example.com")
			s.SetAdminEmails([]string{user.Email})
			token := privySession(t, s, st, user)
			want := http.StatusForbidden
			switch kind {
			case "non_admin_session":
				s.SetAdminEmails([]string{"another-operator@example.com"})
			case "invalid_session":
				token = strings.Split(token, ".")[0] + ".invalid.signature"
				want = http.StatusUnauthorized
			case "admin_inference_key":
				var err error
				token, _, err = st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
				if err != nil {
					t.Fatal(err)
				}
			case "admin_provider_token":
				token = "admin-provider-token"
				if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: sha256Hash(token), AccountID: user.AccountID, Active: true}); err != nil {
					t.Fatal(err)
				}
			case "release_key":
				token, want = "release-key", http.StatusUnauthorized
			case "missing":
				token, want = "", http.StatusUnauthorized
			}
			for _, route := range []struct {
				method, path string
				body         any
			}{
				{http.MethodGet, "/v1/admin/app-attest/builds", nil},
				{http.MethodPost, "/v1/admin/app-attest/builds", qualificationBody(build)},
				{http.MethodPost, "/v1/admin/app-attest/builds/revoke", map[string]string{"binary_hash": build.Release.BinaryHash, "reason": "must be rejected"}},
			} {
				if w := qualificationCall(t, s, route.method, route.path, token, route.body); w.Code != want {
					t.Fatalf("%s %s = %d, want %d: %s", route.method, route.path, w.Code, want, w.Body)
				}
			}
			rows, _ := st.ListAppAttestBuildQualifications(context.Background())
			if len(rows) != 0 {
				t.Fatal("denied request mutated build policy")
			}
		})
	}
}
