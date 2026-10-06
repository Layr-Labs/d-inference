package inference_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func slaAccountRequest(account string) *http.Request {
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	return r.WithContext(access.WithConsumer(r.Context(), account))
}

func TestFirstContentSLAAccountScope(t *testing.T) {
	s, st := testServerWithConfig(t, TestServerConfig{FirstContentSLAAccounts: []string{" partner@example.invalid ", "explicit-account"}, FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	for _, u := range []store.User{
		{AccountID: "openrouter", PrivyUserID: "did:or", Email: "PARTNER@Example.Invalid", Role: store.RoleService},
		{AccountID: "direct", PrivyUserID: "did:direct", Email: "direct@example.com"},
		{AccountID: "other-service", PrivyUserID: "did:other", Email: "other@example.com", Role: store.RoleService},
		{AccountID: "lookalike", PrivyUserID: "did:look", Email: "partner@example.invalid.example.com"},
	} {
		if err := st.CreateUser(&u); err != nil {
			t.Fatal(err)
		}
	}
	for _, account := range []string{"openrouter", "explicit-account", "direct", "other-service", "lookalike", "unknown", ""} {
		for _, model := range []string{"ordinary", "ternary-bonsai-2-27b"} {
			r := slaAccountRequest(account)
			r.Header.Set("User-Agent", "OpenRouter")
			r.Header.Set("X-Account-Email", "partner@example.invalid")
			got, err := s.firstContentPolicy.Deadline(r, model, model, 1000)
			want := time.Duration(0)
			if account == "openrouter" || account == "explicit-account" {
				want = 10 * time.Second
				if model == "ternary-bonsai-2-27b" {
					want = 14 * time.Second
				}
			}
			if err != nil || got != want {
				t.Errorf("%s/%s: %s %v, want %s", account, model, got, err, want)
			}
		}
	}
	blank, _ := testServerWithConfig(t, TestServerConfig{})
	t.Cleanup(blank.Close)
	if got, err := blank.firstContentPolicy.Deadline(slaAccountRequest("openrouter"), "ordinary", "ordinary", 1000); got != 0 || err != nil {
		t.Fatalf("empty selector: %s %v", got, err)
	}
}

func TestFirstContentSLAConfiguredPublicModelPolicy(t *testing.T) {
	const alias = "future-sla-public-model"
	if err := modelpolicy.SetFirstContentSLAsFromEnv(alias + "=20000:7"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = modelpolicy.SetFirstContentSLAsFromEnv(alias + "=off") })
	s, _ := testServerWithConfig(t, TestServerConfig{FirstContentSLAAccounts: []string{"openrouter"}, FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	got, err := s.firstContentPolicy.Deadline(slaAccountRequest("openrouter"), alias, "underlying-build", 1000)
	if err != nil || got != 26*time.Second {
		t.Fatalf("public override: %s %v", got, err)
	}
	if delay := s.firstContentPolicy.HedgeDelay("underlying-build", 1000, got); delay != 13*time.Second {
		t.Fatal(delay)
	}
	got, err = s.firstContentPolicy.Deadline(slaAccountRequest("direct"), alias, "underlying-build", 1000)
	if err != nil || got != 0 {
		t.Fatalf("model policy enabled exempt SLA: %s %v", got, err)
	}
}

type slaIdentityFailureStore struct{ store.Store }

func (s slaIdentityFailureStore) GetUserByAccountID(string) (*store.User, error) {
	return nil, errors.New("identity lookup unavailable")
}

func TestFirstContentSLAIdentityFailureDoesNotSilentlyDisable(t *testing.T) {
	logger := quietLogger()
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	s := newComposedServer(registry.New(logger), slaIdentityFailureStore{st}, TestServerConfig{FirstContentSLAAccounts: []string{"partner@example.invalid", "explicit-account"}}, logger)
	t.Cleanup(s.Close)
	if _, err := s.firstContentPolicy.Deadline(slaAccountRequest("unknown"), "ordinary", "ordinary", 10); err == nil {
		t.Fatal("lookup failure silently bypassed SLA")
	}
	if got, err := s.firstContentPolicy.Deadline(slaAccountRequest("explicit-account"), "ordinary", "ordinary", 10); err != nil || got <= 0 {
		t.Fatalf("ID selector needed lookup: %s %v", got, err)
	}
}
