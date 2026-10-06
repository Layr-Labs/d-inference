package accounts_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureDelayedLiveCheckoutAfterReferrerErasure(t *testing.T) {
	srv, st := newErasureServer(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		io.WriteString(w, `{"id":"cs_late_referrer","url":"https://checkout.example/late"}`)
	}))
	defer fake.Close()
	defer unblock()
	prev := billing.SetStripeAPIBaseForTest(fake.URL)
	defer billing.SetStripeAPIBaseForTest(prev)
	srv.SetBilling(billing.NewService(st, srv.ledger, slog.Default(), billing.Config{StripeSecretKey: "sk_test_review"}))
	a, b := erasurefixture.SeedAccount(t, st), erasurefixture.SeedAccount(t, st)
	if err := st.CreateReferrer(a.AccountID, "PERSONAL-CODE"); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/create-session", strings.NewReader(`{"amount_usd":"1.00","referral_code":"PERSONAL-CODE"}`))
	r.Header.Set("Authorization", "Bearer "+b.RawKey)
	done := make(chan struct{})
	go func() { srv.Handler().ServeHTTP(w, r); close(done) }()
	defer func() { unblock(); <-done }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("checkout did not reach local Stripe")
	}
	req := erasurefixture.PlanAndConfirm(t, st, a, time.Now().UTC(), 0)
	_, err := st.ScrubAccount(context.Background(), req.ID, time.Now().UTC())
	unblock()
	<-done
	if err != nil {
		t.Fatal(err)
	}
	if w.Code != http.StatusOK {
		t.Fatalf("unexpected checkout status: %d %s", w.Code, w.Body.String())
	}
	var body struct {
		SessionID string `json:"session_id"`
	}
	if err = json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	bs, err := st.GetBillingSession(body.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if bs.ReferralCode == "PERSONAL-CODE" {
		t.Fatalf("real HTTP checkout persisted erased referrer's personal code: %+v", bs)
	}
}

type erasureDelayedReader struct {
	r                *strings.Reader
	once             sync.Once
	entered, release chan struct{}
}

func (r *erasureDelayedReader) Read(p []byte) (int, error) {
	r.once.Do(func() { close(r.entered); <-r.release })
	return r.r.Read(p)
}

func TestErasureDelayedAdmittedLogUploadAfterErasure(t *testing.T) {
	srv, st := newErasureServer(t)
	a := erasurefixture.SeedAccount(t, st)
	gate := &erasureDelayedReader{r: strings.NewReader("personal raw log"), entered: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(gate.release) }) }
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/provider/log-report", gate)
	r.Header.Set("Authorization", "Bearer "+a.RawKey)
	done := make(chan struct{})
	go func() { srv.Handler().ServeHTTP(w, r); close(done) }()
	defer func() { unblock(); <-done }()
	select {
	case <-gate.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("log upload did not enter body read")
	}
	req := erasurefixture.PlanAndConfirm(t, st, a, time.Now().UTC(), 0)
	_, err := st.ScrubAccount(context.Background(), req.ID, time.Now().UTC())
	unblock()
	<-done
	if err != nil {
		t.Fatal(err)
	}
	if w.Code != http.StatusConflict {
		t.Fatalf("admitted upload after scrub = %d %s, want 409", w.Code, w.Body.String())
	}
}
