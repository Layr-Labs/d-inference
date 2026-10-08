package accounts_test

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCheckoutCreationAfterErasureRetainsCleanup(t *testing.T) {
	srv, st := newErasureServer(t)
	entered, release := make(chan struct{}), make(chan struct{})
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/checkout/sessions" {
			t.Errorf("unexpected path %s", r.URL.Path)
			http.Error(w, "unexpected", 500)
			return
		}
		close(entered)
		<-release
		io.WriteString(w, `{"id":"cs_late_created","url":"https://checkout.example/late"}`)
	}))
	defer fake.Close()
	prev := billing.SetStripeAPIBaseForTest(fake.URL)
	defer billing.SetStripeAPIBaseForTest(prev)
	srv.SetBilling(billing.NewService(st, srv.ledger, slog.Default(), billing.Config{StripeSecretKey: "sk_test_review"}))
	a := erasurefixture.SeedAccount(t, st)
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/create-session", strings.NewReader(`{"amount_usd":"1.00","email":"person@example.com"}`))
	r.Header.Set("Authorization", "Bearer "+a.RawKey)
	done := make(chan struct{})
	go func() { srv.Handler().ServeHTTP(w, r); close(done) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("checkout did not reach fake Stripe")
	}
	req := erasurefixture.PlanAndConfirm(t, st, a, time.Now().UTC(), 0)
	if _, err := st.ScrubAccount(context.Background(), req.ID, time.Now().UTC()); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	<-done
	var body map[string]any
	json.Unmarshal(w.Body.Bytes(), &body)
	t.Logf("checkout response after erasure: %d %v", w.Code, body)
	if w.Code != http.StatusConflict {
		t.Fatalf("Checkout after erase status=%d, want409", w.Code)
	}
	_, outbox, err := st.GetAccountErasure(context.Background(), a.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	for _, o := range outbox {
		if o.Target == store.ErasureTargetCheckoutSessions && o.ExternalID == "cs_late_created" {
			return
		}
	}
	t.Fatal("late Checkout has no erasure outbox row")
}
