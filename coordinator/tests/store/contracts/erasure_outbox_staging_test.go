package store_test

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// External calls begun before confirmation can return during the grace period.
// Cancellation must preserve those IDs without authorizing deletion; a later
// scrub must combine them with the account's original and subsequently live IDs.
func TestErasureOutboxStagingSurvivesCancellation(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			a := erasurefixture.SeedAccount(t, s)
			global, ok := store.As[store.GlobalPayoutStore](s)
			if !ok {
				t.Fatal("missing global payout capability")
			}
			recipient := store.GlobalRecipient{ID: uniqueID("recipient-generation"), AccountID: a.AccountID, Country: "US"}
			if _, err := global.PrepareGlobalRecipient(recipient); err != nil {
				t.Fatal(err)
			}
			recipient.RecipientID = uniqueID("recipient-original")
			if err := global.SaveGlobalRecipient(recipient); err != nil {
				t.Fatal(err)
			}
			want := map[store.ErasureTarget]map[string]bool{
				store.ErasureTargetStripeAccount:    {a.Stripe: true},
				store.ErasureTargetGlobalRecipient:  {recipient.RecipientID: true},
				store.ErasureTargetCheckoutSessions: {a.Checkout: true},
			}
			assertUnclaimable := func(state string) {
				t.Helper()
				at := time.Now().Add(time.Hour)
				rows, err := s.LeaseDueErasureOutbox(ctx, at, at, time.Minute, 100)
				if err != nil || len(rows) != 0 {
					t.Fatalf("%s staged deliveries: %+v, %v", state, rows, err)
				}
			}
			stageLateObjects := func() {
				t.Helper()
				lateRecipient := recipient
				lateRecipient.RecipientID = uniqueID("recipient-late")
				session := &store.BillingSession{ID: uniqueID("billing-late"), AccountID: a.AccountID, PaymentMethod: "stripe", ExternalID: uniqueID("cs-late"), Status: "pending", CreatedAt: time.Now()}
				stripe := uniqueID("acct-late")
				for label, err := range map[string]error{
					"checkout":  s.CreateBillingSession(session),
					"connect":   s.SetUserStripeAccount(a.AccountID, stripe, "ready", "US", "bank", "9999", true),
					"recipient": global.SaveGlobalRecipient(lateRecipient),
				} {
					if !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("late %s result: %v", label, err)
					}
				}
				want[store.ErasureTargetStripeAccount][stripe] = true
				want[store.ErasureTargetGlobalRecipient][lateRecipient.RecipientID] = true
				want[store.ErasureTargetCheckoutSessions][session.ExternalID] = true
			}

			first := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			stageLateObjects()
			assertUnclaimable("pending")
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			assertUnclaimable("canceled")
			// A restored account can pay again. Its new live session must join,
			// rather than replace, cleanup staged under the canceled request.
			liveCheckout := uniqueID("cs-live")
			if err := s.CreateBillingSession(&store.BillingSession{ID: uniqueID("billing-live"), AccountID: a.AccountID, PaymentMethod: "stripe", ExternalID: liveCheckout, Status: "completed", CreatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			want[store.ErasureTargetCheckoutSessions][liveCheckout] = true
			second := erasurefixture.PlanAndConfirm(t, s, a, now.Add(2*time.Minute), 0)
			if second.ID == first.ID {
				t.Fatal("new erasure reused the canceled request")
			}
			stageLateObjects()
			assertUnclaimable("second pending")
			if _, err := s.ScrubAccount(ctx, second.ID, now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			at := now.Add(3 * time.Minute)
			rows, err := s.LeaseDueErasureOutbox(ctx, at, at, time.Minute, 100)
			if err != nil {
				t.Fatal(err)
			}
			got := map[store.ErasureTarget]map[string]bool{}
			logs := 0
			for _, row := range rows {
				if row.RequestID != second.ID || row.AccountID != a.AccountID || row.ErasedAt.IsZero() || row.LeaseGeneration != 1 {
					t.Fatalf("cleanup not owned by the final scrub: %+v", row)
				}
				if row.Target == store.ErasureTargetErasureLog {
					logs++
					continue
				}
				if got[row.Target] == nil {
					got[row.Target] = map[string]bool{}
				}
				for _, id := range strings.Split(row.ExternalID, ",") {
					if got[row.Target][id] {
						t.Errorf("duplicate cleanup for %s %q", row.Target, id)
					}
					got[row.Target][id] = true
				}
			}
			if logs != 1 || !reflect.DeepEqual(got, want) {
				t.Fatalf("claimed cleanup = %+v, logs=%d; want %+v and one log", got, logs, want)
			}
		})
	}
}
