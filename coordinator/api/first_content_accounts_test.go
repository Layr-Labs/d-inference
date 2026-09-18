package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func slaAccountRequest(account string) *http.Request {
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	return r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, account))
}

func TestFirstContentSLAAccountScope(t *testing.T) {
	s, st := testServerWithConfig(t, ServerConfig{FirstContentSLAAccounts: []string{" partner@example.invalid ", "explicit-account"}, FirstContentDeadlineBase: 9 * time.Second})
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
			got, err := s.requestFirstContentDeadline(r, model, model, 1000)
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
	blank, _ := testServerWithConfig(t, ServerConfig{})
	t.Cleanup(blank.Close)
	if got, err := blank.requestFirstContentDeadline(slaAccountRequest("openrouter"), "ordinary", "ordinary", 1000); got != 0 || err != nil {
		t.Fatalf("empty selector: %s %v", got, err)
	}
}

func TestFirstContentSLAConfiguredPublicModelPolicy(t *testing.T) {
	const alias = "future-sla-public-model"
	if err := modelpolicy.SetFirstContentSLAsFromEnv(alias + "=20000:7"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = modelpolicy.SetFirstContentSLAsFromEnv(alias + "=off") })
	s, _ := testServerWithConfig(t, ServerConfig{FirstContentSLAAccounts: []string{"openrouter"}, FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	got, err := s.requestFirstContentDeadline(slaAccountRequest("openrouter"), alias, "underlying-build", 1000)
	if err != nil || got != 26*time.Second {
		t.Fatalf("public override: %s %v", got, err)
	}
	if delay := s.firstContentHedgeDelay("underlying-build", 1000, got); delay != 13*time.Second {
		t.Fatal(delay)
	}
	got, err = s.requestFirstContentDeadline(slaAccountRequest("direct"), alias, "underlying-build", 1000)
	if err != nil || got != 0 {
		t.Fatalf("model policy enabled exempt SLA: %s %v", got, err)
	}
}

type slaIdentityFailureStore struct{ store.Store }

func (s slaIdentityFailureStore) GetUserByAccountID(string) (*store.User, error) {
	return nil, errors.New("identity lookup unavailable")
}

func TestFirstContentSLAIdentityFailureDoesNotSilentlyDisable(t *testing.T) {
	s, st := testServerWithConfig(t, ServerConfig{FirstContentSLAAccounts: []string{"partner@example.invalid", "explicit-account"}})
	t.Cleanup(s.Close)
	s.store = slaIdentityFailureStore{st}
	if _, err := s.requestFirstContentDeadline(slaAccountRequest("unknown"), "ordinary", "ordinary", 10); err == nil {
		t.Fatal("lookup failure silently bypassed SLA")
	}
	if got, err := s.requestFirstContentDeadline(slaAccountRequest("explicit-account"), "ordinary", "ordinary", 10); err != nil || got <= 0 {
		t.Fatalf("ID selector needed lookup: %s %v", got, err)
	}
}

func TestFirstContentSLAExemptionKeepsOperationalBounds(t *testing.T) {
	d := &dispatchState{deadline: 0, speculativeAt: 4 * time.Second, timing: &registry.RequestTiming{ReceivedAt: time.Now().Add(-time.Minute)}}
	if d.firstTokenExpired() {
		t.Fatal("exempt request expired")
	}
	if wait := d.firstTokenWait(-time.Second); wait != inferenceTimeout {
		t.Fatal(wait)
	}
	if wait := d.firstTokenSpeculativeWait(); wait != 4*time.Second {
		t.Fatal("exemption caused immediate hedge", wait)
	}
	if ms, ok := firstContentBudgetMillis(d.timing.ReceivedAt, 0); !ok || ms != 0 {
		t.Fatalf("disabled budget: %d %v", ms, ok)
	}
	if ttftTooSlow(time.Hour, true, 0) {
		t.Fatal("disabled ceiling rejected candidate")
	}
	ctx, cancel := context.WithCancel(context.Background())
	writeCtx, done := firstTokenWriteContext(ctx, d.timing.ReceivedAt, 0)
	defer done()
	if _, set := writeCtx.Deadline(); set {
		t.Fatal("exempt write inherited SLA")
	}
	cancel()
	select {
	case <-writeCtx.Done():
	default:
		t.Fatal("client cancellation lost")
	}
}

func TestFirstContentSLAAccountsEnvironment(t *testing.T) {
	t.Setenv("EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS", " partner@example.invalid , account-2 ")
	cfg := ReadServerConfig()
	if len(cfg.FirstContentSLAAccounts) != 2 || cfg.FirstContentSLAAccounts[0] != "partner@example.invalid" || cfg.FirstContentSLAAccounts[1] != "account-2" {
		t.Fatal(cfg.FirstContentSLAAccounts)
	}
}

func TestFirstContentSLAExemptQueueWaitHonorsClientCancellation(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.AfterFunc(80*time.Millisecond, cancel)
	defer timer.Stop()
	refunded := false
	d := &dispatchState{
		s: s, w: httptest.NewRecorder(), r: httptest.NewRequest("POST", "/v1/completions", nil).WithContext(ctx),
		model: "exempt-queue", publicModel: "exempt-queue", rawBody: []byte(`{"model":"exempt-queue","messages":[]}`),
		consumerEndpoint: completionsEndpoint, timing: &registry.RequestTiming{ReceivedAt: time.Now().Add(-time.Minute)},
		deadline: 0, speculativeAt: time.Second, refundReservation: func() { refunded = true }, excludeProviders: make(map[string]struct{}),
		requestedMaxTokens: 16, estimatedPromptTokens: 1,
	}
	started := time.Now()
	if got := d.dispatchPrimary(); got != outcomeClientGone {
		t.Fatalf("queue outcome=%v", got)
	}
	if time.Since(started) < 50*time.Millisecond {
		t.Fatal("exemption recreated an expired clock")
	}
	if !refunded || s.registry.Queue().QueueSize(d.model) != 0 {
		t.Fatal("cancelled queue leaked reservation or entry")
	}
}
