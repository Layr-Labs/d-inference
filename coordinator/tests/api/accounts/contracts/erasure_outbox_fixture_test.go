package accounts_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// fakeStripe answers Stripe paths from a per-test table of handlers and
// records each request.
type fakeStripe struct {
	mu       sync.Mutex
	routes   map[string]func(w http.ResponseWriter)
	requests []string
	bodies   map[string]string
	headers  map[string]http.Header
}

func newFakeStripe(t *testing.T) (*fakeStripe, *httptest.Server) {
	t.Helper()
	f := &fakeStripe{routes: map[string]func(http.ResponseWriter){}, bodies: map[string]string{}, headers: map[string]http.Header{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		key := r.Method + " " + r.URL.Path
		f.mu.Lock()
		f.requests = append(f.requests, key)
		f.bodies[key] = string(b)
		f.headers[key] = r.Header.Clone()
		h := f.routes[key]
		f.mu.Unlock()
		if h == nil {
			w.WriteHeader(http.StatusNotImplemented)
			return
		}
		h(w)
	}))
	t.Cleanup(srv.Close)
	return f, srv
}

func (f *fakeStripe) on(method, path string, status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.routes[method+" "+path] = func(w http.ResponseWriter) {
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}
}

func (f *fakeStripe) body(key string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bodies[key]
}

func (f *fakeStripe) header(key, name string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.headers[key].Get(name)
}

func (f *fakeStripe) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, r := range f.requests {
		if r == key {
			n++
		}
	}
	return n
}

func (f *fakeStripe) total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

// datadogIntake is a Logs API intake that records the posted events.
type datadogIntake struct {
	mu     sync.Mutex
	status int
	events []datadogEvent
}

type datadogEvent struct {
	DDTags  string         `json:"ddtags"`
	Message string         `json:"message"`
	Attrs   map[string]any `json:"attributes"`
}

func (d *datadogIntake) setStatus(status int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status = status
}

// erasureLogEvents returns the posted events tagged erasure_log.
func (d *datadogIntake) erasureLogEvents() []datadogEvent {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []datadogEvent
	for _, e := range d.events {
		if strings.Contains(e.DDTags, "erasure_log:true") {
			out = append(out, e)
		}
	}
	return out
}

// intakeTransport sends every Datadog request to the intake server.
type intakeTransport struct{ target *url.URL }

func (t intakeTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	out := req.Clone(req.Context())
	address := *req.URL
	address.Scheme, address.Host = t.target.Scheme, t.target.Host
	out.URL = &address
	return http.DefaultTransport.RoundTrip(out)
}

// newDatadogClient returns a real Datadog client whose Logs API requests
// reach an in-process intake, and the intake.
func newDatadogClient(t *testing.T) (*datadog.Client, *datadogIntake) {
	t.Helper()
	intake := &datadogIntake{status: http.StatusAccepted}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var events []datadogEvent
		if r.URL.Path == "/api/v2/logs" && r.Header.Get("Dd-Api-Key") == "dd-test-key" {
			_ = json.NewDecoder(r.Body).Decode(&events)
		}
		intake.mu.Lock()
		intake.events = append(intake.events, events...)
		status := intake.status
		intake.mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(srv.Close)
	target, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	statsd, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = statsd.Close() })
	client, err := datadog.NewClient(datadog.Config{
		APIKey: "dd-test-key", StatsdAddr: statsd.LocalAddr().String(), FlushSecs: 3600,
		HTTPClient: &http.Client{Timeout: 5 * time.Second, Transport: intakeTransport{target: target}},
	}, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client, intake
}

// outboxFixture is a composed server whose billing service uses real Stripe
// clients pointed at a fake Stripe.
type outboxFixture struct {
	srv    *api.Server
	st     *memory.MemoryStore
	stripe *fakeStripe
}

func newOutboxFixture(t *testing.T, mock bool) *outboxFixture {
	t.Helper()
	f, fake := newFakeStripe(t)
	logger := slog.New(slog.DiscardHandler)
	st := memory.NewMemory(store.Config{})
	ledger := payments.NewLedger(st)
	srv := api.NewRuntime(api.RuntimeDependencies{Registry: registry.New(logger), Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger}, api.ServerConfig{}).Server
	t.Cleanup(srv.Close)
	srv.SetAdminKey("admin-key")
	cfg := billing.Config{MockMode: mock}
	if !mock {
		cfg.StripeSecretKey, cfg.StripeConnectSecretKey = "sk_test_checkout", "sk_test_connect"
		cfg.StripeGlobalPayoutsSecretKey, cfg.StripeGlobalPayoutsFinancialAccount = "sk_test_global", "fa_test"
	}
	prev := billing.SetStripeAPIBaseForTest(fake.URL)
	t.Cleanup(func() { billing.SetStripeAPIBaseForTest(prev) })
	srv.SetBilling(billing.NewService(st, ledger, logger, cfg))
	if gp := srv.Billing().GlobalPayouts(); gp != nil {
		gp.BaseURL = fake.URL
	}
	return &outboxFixture{srv: srv, st: st, stripe: f}
}

// outboxSeed is the Stripe data of an account to erase.
type outboxSeed struct {
	stripeAccount string
	recipient     string
	sessions      []string
	// scrubAt is when the account was scrubbed (and the outbox rows made);
	// zero means now.
	scrubAt time.Time
}

// scrub creates an account with the seed's Stripe data, erases it and
// returns the account ID. The scrub queues the outbox rows.
func (fx *outboxFixture) scrub(t *testing.T, seed outboxSeed) string {
	t.Helper()
	ctx := context.Background()
	at := seed.scrubAt
	if at.IsZero() {
		at = time.Now().UTC()
	}
	a := erasurefixture.Account{AccountID: erasurefixture.UniqueID("acct-outbox")}
	a.Email = a.AccountID + "@example.com"
	if err := fx.st.CreateUser(&store.User{AccountID: a.AccountID, PrivyUserID: "did:privy:" + a.AccountID, Email: a.Email}); err != nil {
		t.Fatal(err)
	}
	if seed.stripeAccount != "" {
		if err := fx.st.SetUserStripeAccount(a.AccountID, seed.stripeAccount, "ready", "US", "bank", "1234", false); err != nil {
			t.Fatal(err)
		}
	}
	if seed.recipient != "" {
		if _, err := fx.st.PrepareGlobalRecipient(store.GlobalRecipient{ID: erasurefixture.UniqueID("gr"), AccountID: a.AccountID, Country: "US", RecipientID: seed.recipient}); err != nil {
			t.Fatal(err)
		}
	}
	for i, cs := range seed.sessions {
		if err := fx.st.CreateBillingSession(&store.BillingSession{
			ID: erasurefixture.UniqueID("bs"), AccountID: a.AccountID, PaymentMethod: "stripe", AmountMicroUSD: 1,
			ExternalID: cs, Status: "completed", CreatedAt: at.Add(-time.Hour).Add(time.Duration(i) * time.Second),
		}); err != nil {
			t.Fatal(err)
		}
	}
	req := erasurefixture.PlanAndConfirm(t, fx.st, a, at, 0)
	if _, err := fx.st.ScrubAccount(ctx, req.ID, at); err != nil {
		t.Fatal(err)
	}
	return a.AccountID
}

func (fx *outboxFixture) items(t *testing.T, account string) []store.ErasureOutboxItem {
	t.Helper()
	_, items, err := fx.st.GetAccountErasure(context.Background(), account)
	if err != nil {
		t.Fatal(err)
	}
	return items
}

// row returns the account's only outbox row for target.
func (fx *outboxFixture) row(t *testing.T, account string, target store.ErasureTarget) store.ErasureOutboxItem {
	t.Helper()
	var found []store.ErasureOutboxItem
	for _, it := range fx.items(t, account) {
		if it.Target == target {
			found = append(found, it)
		}
	}
	if len(found) != 1 {
		t.Fatalf("%s rows = %+v; want one", target, found)
	}
	return found[0]
}

// setRow stores a new state for a pending row through the store's result
// path, due now unless edit moves NextAt.
func (fx *outboxFixture) setRow(t *testing.T, it store.ErasureOutboxItem, edit func(*store.ErasureOutboxResult)) {
	t.Helper()
	r := store.ErasureOutboxResult{
		State: it.State, Attempts: it.Attempts, NextAt: time.Now().UTC(), LastError: it.LastError,
		ExternalID: it.ExternalID, StripeJobID: it.StripeJobID, JobStatus: it.JobStatus,
		JobStatusSince: it.JobStatusSince, JobGeneration: it.JobGeneration,
	}
	if edit != nil {
		edit(&r)
	}
	if err := fx.st.SaveErasureOutboxResult(context.Background(), it.ID, r); err != nil {
		t.Fatal(err)
	}
}

// pass starts the outbox loop, waits until its first pass has stored a
// result for every row of the account that was due, and stops the loop. It
// returns when the pass started.
func (fx *outboxFixture) pass(t *testing.T, account string) time.Time {
	t.Helper()
	start := time.Now().UTC()
	due := map[string]store.ErasureOutboxItem{}
	for _, it := range fx.items(t, account) {
		if it.State == store.ErasureOutboxPending && !it.NextAt.After(start) {
			due[it.ID] = it
		}
	}
	if len(due) == 0 {
		t.Fatal("no outbox row is due")
	}
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	fx.srv.StartErasureOutboxLoop(ctx)
	deadline := time.Now().Add(5 * time.Second)
	for {
		delivered := 0
		for _, it := range fx.items(t, account) {
			before, ok := due[it.ID]
			if ok && (it.State != store.ErasureOutboxPending || it.NextAt.After(start) ||
				it.Attempts != before.Attempts || it.JobGeneration != before.JobGeneration) {
				delivered++
			}
		}
		if delivered == len(due) {
			return start
		}
		if time.Now().After(deadline) {
			t.Fatalf("outbox pass delivered %d of %d due rows: %+v", delivered, len(due), fx.items(t, account))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func wantDone(t *testing.T, it store.ErasureOutboxItem) {
	t.Helper()
	if it.State != store.ErasureOutboxDone || it.ExternalID != "" || it.StripeJobID != "" || it.DoneAt == nil {
		t.Fatalf("row = %+v; want done with its Stripe IDs cleared", it)
	}
}

func wantManual(t *testing.T, it store.ErasureOutboxItem, errPart string) {
	t.Helper()
	if it.State != store.ErasureOutboxManualAction || !strings.Contains(it.LastError, errPart) {
		t.Fatalf("row = %+v; want manual_action with %q", it, errPart)
	}
}

// wantRetry checks a pending row that counted a failed attempt.
func wantRetry(t *testing.T, it store.ErasureOutboxItem, attempts int) {
	t.Helper()
	if it.State != store.ErasureOutboxPending || it.Attempts != attempts || it.LastError == "" {
		t.Fatalf("row = %+v; want pending retry %d", it, attempts)
	}
}

// wantNextAt checks that NextAt is delay after a moment between start and now.
func wantNextAt(t *testing.T, it store.ErasureOutboxItem, start time.Time, delay time.Duration) {
	t.Helper()
	if it.NextAt.Before(start.Add(delay)) || it.NextAt.After(time.Now().Add(delay)) {
		t.Fatalf("next_at = %v after the pass; want %v", it.NextAt.Sub(start), delay)
	}
}

func caseID(prefix string, i int) string { return prefix + strconv.Itoa(i) }
