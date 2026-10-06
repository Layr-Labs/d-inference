package accounts_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestErasureOutboxClaimsOnlyAtDelivery(t *testing.T) {
	fx := newOutboxFixture(t, false)
	accounts := []string{
		fx.scrub(t, outboxSeed{stripeAccount: "acct_first"}),
		fx.scrub(t, outboxSeed{stripeAccount: "acct_second"}),
	}
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	fx.stripe.mu.Lock()
	for _, id := range []string{"acct_first", "acct_second"} {
		fx.stripe.routes["DELETE /v1/accounts/"+id] = func(w http.ResponseWriter) {
			entered <- struct{}{}
			<-release
			_, _ = io.WriteString(w, `{"deleted":true}`)
		}
	}
	fx.stripe.mu.Unlock()
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	fx.srv.StartErasureOutboxLoop(ctx)
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("first Stripe delivery never started")
	}
	// A second coordinator can claim the other account while the first is
	// blocked on Stripe. Batch leasing used to reserve both for ten minutes.
	now := time.Now().UTC()
	rows, err := fx.st.LeaseDueErasureOutbox(context.Background(), now, now, time.Minute, 20)
	if err != nil {
		t.Fatal(err)
	}
	stripeRows := 0
	for _, row := range rows {
		if row.Target == store.ErasureTargetStripeAccount {
			stripeRows++
		}
	}
	if stripeRows != 1 {
		t.Fatalf("other worker claimed %d Stripe rows for %v; want one", stripeRows, accounts)
	}
	stop()
	unblock()
}

func TestErasureOutboxDiscardsStaleStripeCallback(t *testing.T) {
	saved := make(chan error, 1)
	fx := newOutboxFixtureWithLogger(t, false, slog.New(outboxSaveLog{saved: saved}))
	account := fx.scrub(t, outboxSeed{sessions: []string{"cs_late_response"}})
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	fx.stripe.mu.Lock()
	fx.stripe.routes["POST /v1/privacy/redaction_jobs"] = func(w http.ResponseWriter) {
		close(entered)
		<-release
		_, _ = io.WriteString(w, `{"id":"prj_stale","status":"validating"}`)
	}
	fx.stripe.mu.Unlock()
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	fx.srv.StartErasureOutboxLoop(ctx)
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("Stripe create never started")
	}
	later := time.Now().UTC().Add(11 * time.Minute)
	rows, err := fx.st.LeaseDueErasureOutbox(ctx, later, later, time.Minute, 20)
	if err != nil {
		t.Fatal(err)
	}
	var reclaimed bool
	for _, row := range rows {
		result := store.ErasureOutboxResult{LeaseGeneration: row.LeaseGeneration, State: store.ErasureOutboxDone, NextAt: later}
		if row.Target == store.ErasureTargetCheckoutSessions {
			reclaimed = true
			result.State, result.ExternalID = store.ErasureOutboxPending, row.ExternalID
			result.StripeJobID, result.JobGeneration = "prj_current", 1
		}
		if err := fx.st.SaveErasureOutboxResult(ctx, row.ID, result); err != nil {
			t.Fatal(err)
		}
	}
	if !reclaimed {
		t.Fatal("checkout lease was not reclaimed")
	}
	unblock()
	select {
	case err := <-saved:
		if !errors.Is(err, store.ErrErasureConflict) {
			t.Fatalf("stale callback save = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("worker did not reject the stale result")
	}
	row := fx.row(t, account, store.ErasureTargetCheckoutSessions)
	if row.State != store.ErasureOutboxPending || row.StripeJobID != "prj_current" || row.JobGeneration != 1 || !row.NextAt.Equal(later) {
		t.Fatalf("late Stripe response changed current job: %+v", row)
	}
}

// Observe the worker's real result boundary without adding a production seam.
type outboxSaveLog struct{ saved chan error }

func (h outboxSaveLog) Enabled(context.Context, slog.Level) bool { return true }
func (h outboxSaveLog) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h outboxSaveLog) WithGroup(string) slog.Handler            { return h }
func (h outboxSaveLog) Handle(_ context.Context, record slog.Record) error {
	if record.Message == "erasure outbox: save result failed" {
		record.Attrs(func(a slog.Attr) bool {
			if a.Key == "error" {
				err, _ := a.Value.Any().(error)
				h.saved <- err
			}
			return true
		})
	}
	return nil
}
