package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSmallModelsInterestAuthenticatedRegistration(t *testing.T) {
	srv, st := newKeyTestServer(t)
	user := seedUser(t, st, "interest-a", "a@example.test")
	token := privySession(t, srv, st, user)
	r := httptest.NewRequest(http.MethodPost, "/v1/interest/small-models", strings.NewReader(`{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16}`))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("503-A01 authenticated registration: status=%d, want204; body=%s", w.Code, w.Body.String())
	}
	if w.Body.Len() != 0 {
		t.Fatalf("204 must have no body: %s", w.Body.String())
	}
}

const interestBody = `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16}`

func interestCall(srv *Server, method, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)
	return w
}

func TestSmallModelsInterestRejectsNonInteractiveAuth(t *testing.T) {
	for _, kind := range []string{"missing", "invalid", "inference", "provider", "admin"} {
		t.Run(kind, func(t *testing.T) {
			srv, st := newKeyTestServer(t)
			user := seedUser(t, st, "interest-auth", "auth@example.test")
			token := privySession(t, srv, st, user)
			want := http.StatusForbidden
			switch kind {
			case "missing":
				token, want = "", http.StatusUnauthorized
			case "invalid":
				token, want = "eyJ.invalid.signature", http.StatusUnauthorized
			case "inference":
				var err error
				token, _, err = st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
				if err != nil {
					t.Fatal(err)
				}
			case "provider":
				token = "synthetic-provider"
				if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: sha256Hash(token), AccountID: user.AccountID, Active: true}); err != nil {
					t.Fatal(err)
				}
			case "admin":
				token = "synthetic-admin"
				srv.SetAdminKey(token)
			}
			for _, method := range []string{http.MethodPost, http.MethodGet} {
				if w := interestCall(srv, method, "/v1/interest/small-models", token, interestBody); w.Code != want {
					t.Fatalf("%s status%d want%d: %s", method, w.Code, want, w.Body)
				}
			}
			rows, _ := st.ListSmallModelsInterest(context.Background(), "", 100)
			if len(rows) != 0 {
				t.Fatal("unauthorized registration wrote data")
			}
		})
	}
}

func TestSmallModelsInterestInputValidation(t *testing.T) {
	inputs := map[string]string{
		"identity": `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16,"account_id":"other"}`,
		"email":    `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16,"email":"other@example.test"}`,
		"unknown":  `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16,"extra":1}`,
		"mac":      `{"mac_type":"Other","chip":"M1","ram_gb":16}`,
		"chip":     `{"mac_type":"MacBook Pro","chip":" ","ram_gb":16}`,
		"fraction": `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":16.5}`,
		"ram_zero": `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":0}`,
		"ram_high": `{"mac_type":"MacBook Pro","chip":"M1","ram_gb":2049}`,
		"trailing": interestBody + ` {}`, "malformed": `{`, "null": `null`,
		"chip_long": `{"mac_type":"MacBook Pro","chip":"` + strings.Repeat("M", 129) + `","ram_gb":16}`,
		"oversized": interestBody + strings.Repeat(" ", 1024),
	}
	for name, body := range inputs {
		t.Run(name, func(t *testing.T) {
			srv, st := newKeyTestServer(t)
			u := seedUser(t, st, "interest-validation", "v@example.test")
			token := privySession(t, srv, st, u)
			w := interestCall(srv, http.MethodPost, "/v1/interest/small-models", token, body)
			want := http.StatusBadRequest
			if name == "oversized" {
				want = http.StatusRequestEntityTooLarge
			}
			if w.Code != want {
				t.Fatalf("status%d want%d: %s", w.Code, want, w.Body)
			}
			if _, err := st.GetSmallModelsInterest(context.Background(), u.AccountID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("invalid write: %v", err)
			}
		})
	}
	t.Run("email_required", func(t *testing.T) {
		srv, st := newKeyTestServer(t)
		u := seedUser(t, st, "interest-noemail", "")
		token := privySession(t, srv, st, u)
		if w := interestCall(srv, http.MethodPost, "/v1/interest/small-models", token, interestBody); w.Code != 422 {
			t.Fatalf("status%d", w.Code)
		}
	})
}

func TestSmallModelsInterestOwnReadbackAndRateLimit(t *testing.T) {
	srv, st := newKeyTestServer(t)
	a := seedUser(t, st, "interest-a", "a@example.test")
	b := seedUser(t, st, "interest-b", "b@example.test")
	token := privySession(t, srv, st, a)
	if w := interestCall(srv, http.MethodPost, "/v1/interest/small-models", token, interestBody); w.Code != 204 {
		t.Fatal(w.Body)
	}
	if w := interestCall(srv, http.MethodGet, "/v1/interest/small-models?account_id=interest-b", token, ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"account_id":"interest-a"`) {
		t.Fatalf("own read: %d %s", w.Code, w.Body)
	}
	token = privySession(t, srv, st, b)
	if w := interestCall(srv, http.MethodGet, "/v1/interest/small-models?account_id=interest-a", token, ""); w.Code != 404 {
		t.Fatalf("B read leaked A: %d %s", w.Code, w.Body)
	}
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	if w := interestCall(srv, http.MethodPost, "/v1/interest/small-models", token, interestBody); w.Code != 204 {
		t.Fatal(w.Body)
	}
	w := interestCall(srv, http.MethodPost, "/v1/interest/small-models", token, strings.Replace(interestBody, "16", "32", 1))
	if w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatalf("rate limit: %d %s", w.Code, w.Body)
	}
	got, _ := st.GetSmallModelsInterest(context.Background(), b.AccountID)
	if got.RAMGB != 16 {
		t.Fatal("rate-limited write changed hardware")
	}
}

type failedInterestStore struct{ store.Store }

func (failedInterestStore) UpsertSmallModelsInterest(context.Context, store.SmallModelsInterest) error {
	return errors.New("unavailable")
}
func (failedInterestStore) GetSmallModelsInterest(context.Context, string) (*store.SmallModelsInterest, error) {
	return nil, errors.New("unavailable")
}
func TestSmallModelsInterestStorageFailure(t *testing.T) {
	srv, st := newKeyTestServer(t)
	u := seedUser(t, st, "interest-error", "error@example.test")
	token := privySession(t, srv, st, u)
	srv.store = failedInterestStore{Store: st}
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		if w := interestCall(srv, method, "/v1/interest/small-models", token, interestBody); w.Code != 500 {
			t.Fatalf("%s returned%d", method, w.Code)
		}
	}
}

func TestSmallModelsInterestAdminExport(t *testing.T) {
	srv, st := newKeyTestServer(t)
	a := seedUser(t, st, "interest-a", "a@example.test")
	b := seedUser(t, st, "interest-b", "b@example.test")
	for _, u := range []*store.User{a, b} {
		if err := st.UpsertSmallModelsInterest(context.Background(), store.SmallModelsInterest{AccountID: u.AccountID, MacType: "MacBook Pro", Chip: "M1", RAMGB: 16}); err != nil {
			t.Fatal(err)
		}
	}
	srv.SetAdminEmails([]string{a.Email})
	srv.SetAdminKey("synthetic-admin")
	admin := privySession(t, srv, st, a)
	for _, token := range []string{admin, "synthetic-admin"} {
		cursor := ""
		emails := []string{}
		for i := 0; i < 3; i++ {
			w := interestCall(srv, http.MethodGet, "/v1/admin/interest/small-models?limit=1&after="+cursor, token, "")
			if w.Code != 200 {
				t.Fatalf("admin: %d %s", w.Code, w.Body)
			}
			var page struct {
				Data []store.SmallModelsInterestContact `json:"data"`
				Next string                             `json:"next_cursor"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
				t.Fatal(err)
			}
			for _, row := range page.Data {
				emails = append(emails, row.Email)
			}
			cursor = page.Next
			if cursor == "" {
				break
			}
		}
		if strings.Join(emails, ",") != "a@example.test,b@example.test" {
			t.Fatalf("export=%v", emails)
		}
		if w := interestCall(srv, http.MethodGet, "/v1/admin/interest/small-models?limit=101", token, ""); w.Code != 400 {
			t.Fatalf("unbounded page status%d", w.Code)
		}
	}
	key, _, err := st.CreateAPIKey(a.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	if w := interestCall(srv, http.MethodGet, "/v1/admin/interest/small-models", key, ""); w.Code != 403 {
		t.Fatalf("admin inference key status%d", w.Code)
	}
	nonadmin := privySession(t, srv, st, b)
	if w := interestCall(srv, http.MethodGet, "/v1/admin/interest/small-models", nonadmin, ""); w.Code != 403 {
		t.Fatalf("nonadmin status%d", w.Code)
	}
	if w := interestCall(srv, http.MethodGet, "/v1/admin/interest/small-models", "", ""); w.Code != 401 {
		t.Fatalf("missing auth status%d", w.Code)
	}
}

func TestSmallModelsInterestBaselineAuthControl(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/keys", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("existing interactive auth control: status=%d, want401", w.Code)
	}
}
