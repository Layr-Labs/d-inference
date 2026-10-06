package store_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureLateExternalObjectsRemainInCleanup(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			global, ok := store.As[store.GlobalPayoutStore](s)
			if !ok {
				t.Fatal("missing global payout capability")
			}
			for _, scrubFirst := range []bool{false, true} {
				t.Run(map[bool]string{false: "pending", true: "erased"}[scrubFirst], func(t *testing.T) {
					ctx := context.Background()
					now := time.Now().UTC()
					a := erasurefixture.SeedAccount(t, s)
					recipient := store.GlobalRecipient{ID: erasurefixture.UniqueID("generation"), AccountID: a.AccountID, Country: "US"}
					if _, err := global.PrepareGlobalRecipient(recipient); err != nil {
						t.Fatal(err)
					}
					req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
					if scrubFirst {
						if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
							t.Fatal(err)
						}
					}
					session := &store.BillingSession{ID: erasurefixture.UniqueID("late-session"), AccountID: a.AccountID, PaymentMethod: "stripe", ExternalID: erasurefixture.UniqueID("cs-late"), Status: "pending", CreatedAt: now}
					stripe := erasurefixture.UniqueID("acct-late")
					recipient.RecipientID = erasurefixture.UniqueID("recipient-late")
					recipient.Last4 = "9999"
					recipient.Ready = true
					for label, err := range map[string]error{
						"checkout":  s.CreateBillingSession(session),
						"connect":   s.SetUserStripeAccount(a.AccountID, stripe, "ready", "US", "bank", "9999", true),
						"recipient": global.SaveGlobalRecipient(recipient),
					} {
						if !errors.Is(err, store.ErrErasureConflict) {
							t.Fatalf("%s: %v", label, err)
						}
					}
					if !scrubFirst {
						if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
							t.Fatal(err)
						}
					}
					_, outbox, err := s.GetAccountErasure(ctx, a.AccountID)
					if err != nil {
						t.Fatal(err)
					}
					for target, id := range map[store.ErasureTarget]string{store.ErasureTargetCheckoutSessions: session.ExternalID, store.ErasureTargetStripeAccount: stripe, store.ErasureTargetGlobalRecipient: recipient.RecipientID} {
						found := false
						for _, item := range outbox {
							if item.Target == target && strings.Contains(item.ExternalID, id) {
								found = true
							}
						}
						if !found {
							t.Errorf("no durable cleanup for %s", target)
						}
					}
					stored, err := s.GetBillingSession(session.ID)
					if err != nil || stored.Status != "erased" || stored.ExternalID != "" {
						t.Fatalf("late session remains usable: %+v %v", stored, err)
					}
					got, err := global.GetGlobalRecipient(a.AccountID)
					if err != nil || got.RecipientID != "" || got.Last4 != "" || got.Ready {
						t.Fatalf("late recipient resurrected: %+v %v", got, err)
					}
					plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
					if err != nil {
						t.Fatal(err)
					}
					if len(plan.StripeObjects) != 0 {
						t.Fatalf("external objects restored after scrub: %+v", plan.StripeObjects)
					}
				})
			}
		})
	}
}

func TestErasureLateTelemetryKeepsAccountingWithoutLocations(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			a := erasurefixture.SeedAccount(t, s)
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}
			before, err := s.UsageTotals()
			if err != nil {
				t.Fatal(err)
			}
			s.RecordUsage(store.UsageRecord{ConsumerKey: a.AccountID, ProviderID: a.ProviderID, RequestID: erasurefixture.UniqueID("usage-late"), Model: "model", PromptTokens: 7, CompletionTokens: 3, RequestLocation: &store.ProviderLocation{City: "private-city"}})
			route := &store.InferenceRouteRecord{RequestID: erasurefixture.UniqueID("route-late"), Attempt: 1, ConsumerKeyHash: store.HashKey(a.AccountID), ProviderID: a.ProviderID, ConsumerRegion: "private-consumer", ProviderRegion: "private-provider"}
			if err := s.RecordInferenceRoute(route); err != nil {
				t.Fatal(err)
			}
			route.RequestID = erasurefixture.UniqueID("route-batch-late")
			if err := s.RecordInferenceRoutes([]*store.InferenceRouteRecord{route}); err != nil {
				t.Fatal(err)
			}
			after, err := s.UsageTotals()
			if err != nil {
				t.Fatal(err)
			}
			if after.Requests-before.Requests != 1 || after.PromptTokens-before.PromptTokens != 7 || after.CompletionTokens-before.CompletionTokens != 3 {
				t.Fatalf("late usage accounting lost: before=%+v after=%+v", before, after)
			}
			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			for _, rule := range []string{"usage_request_location", "inference_routes_consumer_region", "inference_routes_provider_region"} {
				if n := erasurefixture.RowsFor(plan.Rows, rule); n != 0 {
					t.Errorf("late %s personal rows=%d", rule, n)
				}
			}
			if route.ConsumerRegion == "" || route.ProviderRegion == "" {
				t.Fatal("store mutated caller route")
			}
		})
	}
}

func TestErasureRefusedOnceCreditsRetainIdentity(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			a := erasurefixture.SeedAccount(t, s)
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}
			for _, ref := range []string{"stripe_withdraw:late", "stripe:private-session", "stripe:another-session"} {
				for attempt := 0; attempt < 2; attempt++ {
					applied, err := s.CreditWithdrawableOnce(a.AccountID, 100, store.LedgerRefund, ref)
					if err != nil || applied != (attempt == 0) {
						t.Fatalf("attempt %d: applied=%t err=%v", attempt, applied, err)
					}
				}
			}
			for i := 0; i < 2; i++ {
				if err := s.CreditWithdrawable(a.AccountID, 200, store.LedgerRefund, "repeatable"); err != nil {
					t.Fatal(err)
				}
			}
			rows, err := s.ListErasureRefusedCredits(ctx, a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 5 {
				t.Fatalf("refused credits=%d, want three once identities and two ordinary credits", len(rows))
			}
			if s.GetBalance(a.AccountID) != 0 {
				t.Fatal("refused credits restored balance")
			}
		})
	}
}
