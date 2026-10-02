package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A dependency barrier leaves the real admission, semaphore, reservation and
// memory-store behavior intact. Tests release it before joining all goroutines.
type terminalEffectBarrier struct {
	entered     chan struct{}
	resume      chan struct{}
	enterOnce   sync.Once
	releaseOnce sync.Once
}

func newTerminalEffectBarrier() *terminalEffectBarrier {
	return &terminalEffectBarrier{entered: make(chan struct{}), resume: make(chan struct{})}
}
func (b *terminalEffectBarrier) block()   { b.enterOnce.Do(func() { close(b.entered) }); <-b.resume }
func (b *terminalEffectBarrier) release() { b.releaseOnce.Do(func() { close(b.resume) }) }

type terminalEffectStore struct {
	store.Store
	refundBarrier *terminalEffectBarrier
	lookupBarrier *terminalEffectBarrier
	refunds       atomic.Int32
	lookups       atomic.Int32
}

func (s *terminalEffectStore) Credit(account string, amount int64, kind store.LedgerEntryType, reference string) error {
	if kind == store.LedgerRefund && reference == "reservation_refund" {
		s.refunds.Add(1)
		if s.refundBarrier != nil {
			s.refundBarrier.block()
		}
	}
	return s.Store.Credit(account, amount, kind, reference)
}
func (s *terminalEffectStore) ListProvidersByAccount(ctx context.Context, account string) ([]store.ProviderRecord, error) {
	s.lookups.Add(1)
	if s.lookupBarrier != nil {
		s.lookupBarrier.block()
	}
	return s.Store.ListProvidersByAccount(ctx, account)
}

type terminalEffectWriter struct {
	*httptest.ResponseRecorder
	barrier *terminalEffectBarrier
}

func (w *terminalEffectWriter) WriteHeader(status int) {
	w.barrier.block()
	w.ResponseRecorder.WriteHeader(status)
}
func (w *terminalEffectWriter) Write(body []byte) (int, error) {
	w.barrier.block()
	return w.ResponseRecorder.Write(body)
}

func terminalEffectServer(t *testing.T) (*Server, *store.MemoryStore, *terminalEffectStore) {
	t.Helper()
	mem := store.NewMemory(store.Config{AdminKey: "test-key"})
	st := &terminalEffectStore{Store: mem}
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.SetBilling(billing.NewService(st, payments.NewLedger(st), logger, billing.Config{MockMode: true}))
	srv.SetRoutingConcurrency(2)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: "terminal-unavailable", SizeGB: 1, MinRAMGB: 24},
		{ID: "terminal-healthy", SizeGB: 1, MinRAMGB: 24},
	})
	registerBuildsProvider(srv, "terminal-control-provider", "terminal-healthy")
	if err := mem.Credit(testConsumerID, 100_000_000, store.LedgerDeposit, "terminal-fixture-seed"); err != nil {
		t.Fatal(err)
	}
	if err := mem.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: "terminal-unavailable", InputPrice: 1_000_000, OutputPrice: 2_000_000}); err != nil {
		t.Fatal(err)
	}
	return srv, mem, st
}

func terminalEffectRequest(endpoint string, self bool) *http.Request {
	body := `{"model":"terminal-unavailable","messages":[{"role":"user","content":"hello"}],"max_tokens":64,"stream":false}`
	if endpoint == "/v1/completions" {
		body = `{"model":"terminal-unavailable","prompt":"hello","max_tokens":64,"stream":false}`
	}
	r := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer test-key")
	r.Header.Set("Content-Type", "application/json")
	if self {
		r.Header.Set("X-Darkbloom-Route", "self")
	}
	return r
}

func terminalHealthyAdmission(t *testing.T, srv *Server) {
	t.Helper()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	var refunds int
	model, handled := srv.runInferenceAdmission(w, r, map[string]any{"model": "terminal-healthy"}, inferenceAdmissionParams{
		model: "terminal-healthy", publicModel: "terminal-healthy", estimatedPromptTokens: 16, requestedMaxTokens: 64,
		deadline: 400 * time.Millisecond, receivedAt: time.Now(), refundReservation: func() { refunds++ },
	})
	if handled || refunds != 0 || model != "terminal-healthy" || w.Body.Len() != 0 {
		t.Errorf("independent healthy admission while terminal effect blocked: handled=%v refunds=%d model=%q status=%d body=%s; want admitted without refund", handled, refunds, model, w.Code, w.Body.String())
	}
}

func assertTerminalResponse(t *testing.T, rec *httptest.ResponseRecorder, mem *store.MemoryStore, st *terminalEffectStore, self bool) {
	t.Helper()
	wantStatus, wantCode, wantRefunds := http.StatusTooManyRequests, "rate_limit_exceeded", int32(1)
	if self {
		wantStatus, wantCode, wantRefunds = http.StatusConflict, "no_linked_machine", 0
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Errorf("terminal response JSON: %v; body=%s", err, rec.Body.String())
	}
	if rec.Code != wantStatus || body.Error.Code != wantCode {
		t.Errorf("terminal status/code=%d/%q, want %d/%q; body=%s", rec.Code, body.Error.Code, wantStatus, wantCode, rec.Body.String())
	}
	if !self {
		wantMessage := `no provider for model "terminal-unavailable" is available right now — retry after 2s`
		if body.Error.Message != wantMessage || rec.Header().Get("Retry-After") != "2" {
			t.Errorf("terminal message/retry=%q/%q, want %q/2", body.Error.Message, rec.Header().Get("Retry-After"), wantMessage)
		}
	} else if rec.Header().Get("Retry-After") != "" {
		t.Errorf("no-linked-machine acquired Retry-After: %q", rec.Header().Get("Retry-After"))
	}
	if got := st.refunds.Load(); got != wantRefunds {
		t.Errorf("legacy refund count=%d, want %d", got, wantRefunds)
	}
	if balance := mem.GetBalance(testConsumerID); balance != 100_000_000 {
		t.Errorf("balance=%d, want restored 100000000", balance)
	}
	var charges, refunds int
	for _, entry := range mem.LedgerHistory(testConsumerID) {
		if entry.Type == store.LedgerCharge {
			charges++
		}
		if entry.Type == store.LedgerRefund {
			refunds++
		}
	}
	if charges != int(wantRefunds) || refunds != int(wantRefunds) {
		t.Errorf("real ledger charges/refunds=%d/%d, want %d/%d", charges, refunds, wantRefunds, wantRefunds)
	}
}

func TestPreflightTerminalEffectsReleaseRoutingScanPermit(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/completions"} {
		for _, effect := range []string{"refund", "writer", "self_lookup"} {
			t.Run(strings.TrimPrefix(endpoint, "/v1/")+"/"+effect, func(t *testing.T) {
				srv, mem, st := terminalEffectServer(t)
				barrier := newTerminalEffectBarrier()
				rec := httptest.NewRecorder()
				var w http.ResponseWriter = rec
				switch effect {
				case "refund":
					st.refundBarrier = barrier
				case "writer":
					w = &terminalEffectWriter{ResponseRecorder: rec, barrier: barrier}
				case "self_lookup":
					st.lookupBarrier = barrier
				}
				srv.routingScanSem <- struct{}{} // foreign permit: admission may only release its own.
				finished := make(chan struct{})
				ctx, cancel := context.WithCancel(context.Background())
				go func() {
					defer close(finished)
					srv.Handler().ServeHTTP(w, terminalEffectRequest(endpoint, effect == "self_lookup").WithContext(ctx))
				}()
				defer func() {
					cancel()
					barrier.release()
					select {
					case <-finished:
					case <-time.After(3 * time.Second):
						t.Error("setup cleanup failure: handler failed to finish after cancellation and terminal barrier release")
					}
				}()
				select {
				case <-barrier.entered:
				case <-finished:
					t.Fatalf("setup: handler missed %s barrier, status=%d body=%s", effect, rec.Code, rec.Body.String())
				case <-time.After(3 * time.Second):
					t.Fatalf("setup: never entered %s barrier", effect)
				}
				held := len(srv.routingScanSem)
				if held != 1 {
					t.Errorf("terminal effect holds a routing permit: occupied=%d, want only one foreign permit", held)
				}
				terminalHealthyAdmission(t, srv)
				barrier.release()
				select {
				case <-finished:
				case <-time.After(3 * time.Second):
					t.Fatal("handler failed to complete")
				}
				assertTerminalResponse(t, rec, mem, st, effect == "self_lookup")
				if got := len(srv.routingScanSem); got != 1 {
					t.Errorf("post-handler occupied=%d, want foreign permit preserved", got)
				}
				select {
				case <-srv.routingScanSem:
				default:
					t.Error("foreign permit was consumed by admission cleanup")
				}
				if got := len(srv.routingScanSem); got != 0 {
					t.Errorf("leaked %d routing permits", got)
				}
			})
		}
	}
}

func TestPreflightTerminalEffectsUnblockedControl(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/completions"} {
		t.Run(strings.TrimPrefix(endpoint, "/v1/"), func(t *testing.T) {
			srv, mem, st := terminalEffectServer(t)
			rec := httptest.NewRecorder()
			srv.Handler().ServeHTTP(rec, terminalEffectRequest(endpoint, false))
			assertTerminalResponse(t, rec, mem, st, false)
			terminalHealthyAdmission(t, srv)
			if got := len(srv.routingScanSem); got != 0 {
				t.Errorf("control leaked %d routing permits", got)
			}
		})
	}
}

// These online self-route branches do not use ListProvidersByAccount. They
// independently pin the final owned-provider evaluation before output begins.
func TestPreflightSelfRouteTerminalWriterReleasesRoutingScanPermit(t *testing.T) {
	for _, reason := range []string{"model_not_loaded", "model_capability_unsupported"} {
		t.Run(reason, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			model := "terminal-unavailable"
			build := "terminal-healthy"
			if reason == "model_capability_unsupported" {
				build = model
			}
			p := registerBuildsProvider(srv, "terminal-owned-provider", build)
			p.Mu().Lock()
			p.AccountID = testConsumerID
			p.Mu().Unlock()
			barrier := newTerminalEffectBarrier()
			rec := httptest.NewRecorder()
			w := &terminalEffectWriter{ResponseRecorder: rec, barrier: barrier}
			srv.routingScanSem <- struct{}{}
			finished := make(chan struct{})
			var refunds atomic.Int32
			var handled bool
			ctx, cancel := context.WithCancel(context.Background())
			go func() {
				defer close(finished)
				_, handled = srv.runInferenceAdmission(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx), map[string]any{"model": model}, inferenceAdmissionParams{
					model: model, publicModel: model, deadline: time.Second, receivedAt: time.Now(),
					policy:         selfRoutePolicy{enabled: true, ownerAccountID: testConsumerID},
					requiresVision: reason == "model_capability_unsupported", refundReservation: func() { refunds.Add(1) },
				})
			}()
			defer func() {
				cancel()
				barrier.release()
				select {
				case <-finished:
				case <-time.After(3 * time.Second):
					t.Error("setup cleanup failure: self-route did not finish after cancellation and barrier release")
				}
			}()
			select {
			case <-barrier.entered:
			case <-finished:
				t.Fatal("setup: self-route returned without writing")
			case <-time.After(3 * time.Second):
				t.Fatal("setup: self-route writer was not reached")
			}
			if got := len(srv.routingScanSem); got != 1 {
				t.Errorf("online self-route writer holds scan permit: occupied=%d, want only foreign permit", got)
			}
			terminalHealthyAdmission(t, srv)
			barrier.release()
			select {
			case <-finished:
			case <-time.After(3 * time.Second):
				t.Fatal("self-route did not complete")
			}
			var body struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if !handled || rec.Code != http.StatusServiceUnavailable || body.Error.Code != reason || refunds.Load() != 1 {
				t.Errorf("self-route handled=%v status=%d code=%q refunds=%d; want handled503/%s/refund1", handled, rec.Code, body.Error.Code, refunds.Load(), reason)
			}
			wantRetry := ""
			if reason == "model_not_loaded" {
				wantRetry = "15"
			}
			if got := rec.Header().Get("Retry-After"); got != wantRetry {
				t.Errorf("Retry-After=%q, want %q", got, wantRetry)
			}
			if got := len(srv.routingScanSem); got != 1 {
				t.Errorf("self-route cleanup consumed foreign permit or leaked own: occupied=%d", got)
			}
			select {
			case <-srv.routingScanSem:
			default:
				t.Error("foreign token missing")
			}
			if len(srv.routingScanSem) != 0 {
				t.Error("self-route leaked permit")
			}
		})
	}
}

// Additional branch controls are kept after the immutable baseline fixture.
func TestPreflightTerminalBranchWritersReleaseRoutingScanPermit(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		code    string
		retry   string
		message string
	}{
		{"servability", 429, "rate_limit_exceeded", "2", "context window"},
		{"model_too_large", 503, "model_unavailable", "", "too large for any"},
		{"capacity", 429, "rate_limit_exceeded", "2", "at capacity"},
		{"dedicated_capacity", 429, "rate_limit_exceeded", "2", "no provider dedicated"},
		{"body_public", 413, "payload_too_large", "", ""},
		{"body_self", 413, "payload_too_large", "", ""},
		{"body_prefer", 413, "payload_too_large", "", ""},
		{"body_self_nonmatching", 503, "model_capability_unsupported", "", "cannot take this request"},
		{"self_offline", 503, "machine_offline", "30", "offline"},
		{"hard_ttft", 429, "rate_limit_exceeded", "nonempty", "TTFT target"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, mem, _ := terminalEffectServer(t)
			const model = "terminal-unavailable"
			var refunds atomic.Int32
			traits := registry.RequestTraits{}
			params := inferenceAdmissionParams{
				model: model, publicModel: model, estimatedPromptTokens: 100, requestedMaxTokens: 64,
				deadline: 5 * time.Second, receivedAt: time.Now(), traits: &traits,
				refundReservation: func() { refunds.Add(1) },
			}
			switch tc.name {
			case "servability":
				params.modelMaxContext = 32
			case "model_too_large":
				t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")
				srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}, {ID: "terminal-healthy", SizeGB: 1, MinRAMGB: 24}})
				p := registerBuildsProvider(srv, "undersized-provider", model)
				p.Mu().Lock()
				p.BackendCapacity.Slots[0].State = "idle_shutdown"
				p.Mu().Unlock()
			case "capacity":
				t.Setenv(envQueueBeforeShed, "false")
				p := registerBuildsProvider(srv, "busy-provider", model)
				p.Mu().Lock()
				p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
				p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 4096
				p.Mu().Unlock()
			case "dedicated_capacity":
				t.Setenv(envColdDispatch, "false")
				srv.registry.SetDedicatedModels([]string{model})
				registerBuildsProvider(srv, "mixed-provider", model, "terminal-healthy")
			case "body_public", "body_self", "body_prefer", "body_self_nonmatching":
				p := registerBuildsProvider(srv, "protocol-zero-provider", model)
				p.Mu().Lock()
				p.AccountID = testConsumerID
				p.Mu().Unlock()
				traits.MinPrefixCacheProtocol = 1
				params.providerBodyErrorForModel = func(string) error {
					if got := len(srv.routingScanSem); got != 2 {
						t.Errorf("body compatibility probe evaluated without its permit: occupied=%d", got)
					}
					if tc.name == "body_self_nonmatching" {
						return nil
					}
					return &providerBodyTooLargeError{size: maxInferenceBodyBytes + 63}
				}
				if tc.name == "body_self" || tc.name == "body_self_nonmatching" {
					params.policy = selfRoutePolicy{enabled: true, ownerAccountID: testConsumerID}
				}
				if tc.name == "body_prefer" {
					params.policy = selfRoutePolicy{prefer: true, ownerAccountID: testConsumerID}
				}
			case "self_offline":
				params.policy = selfRoutePolicy{enabled: true, ownerAccountID: testConsumerID}
				if err := mem.UpsertProvider(context.Background(), store.ProviderRecord{ID: "offline-owned", AccountID: testConsumerID, LastSeen: time.Now().Add(-time.Hour)}); err != nil {
					t.Fatal(err)
				}
			case "hard_ttft":
				srv.ttftHardReject = true
				p := registerBuildsProvider(srv, "slow-provider", model)
				reportMeasuredFirstContentEvidence(t, srv.registry, p.ID, model, 10, 100)
			}
			barrier := newTerminalEffectBarrier()
			rec := httptest.NewRecorder()
			writer := &terminalEffectWriter{ResponseRecorder: rec, barrier: barrier}
			srv.routingScanSem <- struct{}{}
			ctx, cancel := context.WithCancel(context.Background())
			finished := make(chan struct{})
			var handled bool
			go func() {
				defer close(finished)
				_, handled = srv.runInferenceAdmission(writer, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx), map[string]any{"model": model}, params)
			}()
			defer func() {
				cancel()
				barrier.release()
				select {
				case <-finished:
				case <-time.After(3 * time.Second):
					t.Error("setup cleanup failure: terminal branch failed to join")
				}
			}()
			select {
			case <-barrier.entered:
			case <-finished:
				t.Fatalf("setup: %s did not reach a terminal writer: status=%d body=%s", tc.name, rec.Code, rec.Body.String())
			case <-time.After(3 * time.Second):
				t.Fatal("setup: terminal branch writer not reached")
			}
			if got := len(srv.routingScanSem); got != 1 {
				t.Errorf("terminal writer owns scan permit: occupied=%d, want foreign-only1", got)
			}
			terminalHealthyAdmission(t, srv)
			barrier.release()
			select {
			case <-finished:
			case <-time.After(3 * time.Second):
				t.Fatal("setup cleanup failure: terminal branch failed to complete")
			}
			var body struct {
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if !handled || rec.Code != tc.status || body.Error.Code != tc.code || !strings.Contains(body.Error.Message, tc.message) || refunds.Load() != 1 {
				t.Errorf("terminal branch handled=%v status=%d code=%q message=%q refunds=%d; want true/%d/%s/contains%q/refund1", handled, rec.Code, body.Error.Code, body.Error.Message, refunds.Load(), tc.status, tc.code, tc.message)
			}
			retry := rec.Header().Get("Retry-After")
			if (tc.retry == "nonempty" && retry == "") || (tc.retry != "nonempty" && retry != tc.retry) {
				t.Errorf("Retry-After=%q, want %q", retry, tc.retry)
			}
			if len(srv.routingScanSem) != 1 {
				t.Error("terminal cleanup lost foreign token or leaked permit")
			}
			select {
			case <-srv.routingScanSem:
			default:
				t.Error("foreign token missing")
			}
			if len(srv.routingScanSem) != 0 {
				t.Error("terminal branch leaked permit")
			}
		})
	}
}

func TestPreflightTerminalLiveModesKeepReservation(t *testing.T) {
	for _, mode := range []string{"public", "self", "prefer"} {
		t.Run(mode, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			p := srv.registry.GetProvider("terminal-control-provider")
			p.Mu().Lock()
			p.AccountID = testConsumerID
			p.Mu().Unlock()
			policy := selfRoutePolicy{}
			if mode == "self" {
				policy = selfRoutePolicy{enabled: true, ownerAccountID: testConsumerID}
			}
			if mode == "prefer" {
				policy = selfRoutePolicy{prefer: true, ownerAccountID: testConsumerID}
			}
			var refunds int
			srv.routingScanSem <- struct{}{}
			w := httptest.NewRecorder()
			model, handled := srv.runInferenceAdmission(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), map[string]any{"model": "terminal-healthy"}, inferenceAdmissionParams{
				model: "terminal-healthy", publicModel: "terminal-healthy", policy: policy, estimatedPromptTokens: 16, requestedMaxTokens: 64,
				deadline: time.Second, receivedAt: time.Now(), refundReservation: func() { refunds++ },
			})
			if handled || refunds != 0 || model != "terminal-healthy" || w.Body.Len() != 0 {
				t.Errorf("live %s handled=%v refunds=%d model=%s body=%s", mode, handled, refunds, model, w.Body.String())
			}
			if len(srv.routingScanSem) != 1 {
				t.Error("live admission changed foreign permit ownership")
			}
			select {
			case <-srv.routingScanSem:
			default:
				t.Error("foreign token missing")
			}
		})
	}
}

func TestPreflightTerminalFallbackAlreadyHandledOnce(t *testing.T) {
	for _, reason := range []string{"capacity", "ttft"} {
		t.Run(reason, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			const desired, previous, public = "terminal-unavailable", "terminal-healthy", "terminal-alias"
			srv.registry.SetModelAliases(map[string]registry.AliasTarget{public: {Desired: desired, Previous: previous}})
			p := registerBuildsProvider(srv, "fallback-desired", desired)
			if reason == "capacity" {
				p.Mu().Lock()
				p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
				p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 4096
				p.Mu().Unlock()
			} else {
				srv.ttftHardReject = true
				reportMeasuredFirstContentEvidence(t, srv.registry, p.ID, desired, 10, 100)
				reportMeasuredFirstContentEvidence(t, srv.registry, "terminal-control-provider", previous, 1000, 1000)
			}
			w := httptest.NewRecorder()
			var callbacks, refunds int
			srv.routingScanSem <- struct{}{}
			_, handled := srv.runInferenceAdmission(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), map[string]any{"model": desired}, inferenceAdmissionParams{
				model: desired, publicModel: public, estimatedPromptTokens: 100, requestedMaxTokens: 64, deadline: 5 * time.Second, receivedAt: time.Now(),
				refundReservation: func() { refunds++ },
				onModelFallback: func(model string) bool {
					callbacks++
					refunds++
					if model != previous || len(srv.routingScanSem) != 1 {
						t.Errorf("fallback callback model=%s permits=%d, want previous/foreign-only", model, len(srv.routingScanSem))
					}
					w.WriteHeader(http.StatusUnprocessableEntity)
					_, _ = w.Write([]byte("fallback-body-rejected"))
					return false
				},
			})
			if !handled || callbacks != 1 || refunds != 1 || w.Code != http.StatusUnprocessableEntity || w.Body.String() != "fallback-body-rejected" {
				t.Errorf("handled callback applied twice or lost: handled=%v callbacks=%d refunds=%d status=%d body=%s", handled, callbacks, refunds, w.Code, w.Body.String())
			}
			if len(srv.routingScanSem) != 1 {
				t.Error("already-handled cleanup consumed foreign permit")
			}
			select {
			case <-srv.routingScanSem:
			default:
				t.Error("foreign token missing")
			}
		})
	}
}
