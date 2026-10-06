package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestBillingSessionLifecycleBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			referrerAccountID, referralCode := uniqueID("referrer"), uniqueID("REF")
			if err := s.CreateUser(&store.User{AccountID: referrerAccountID, PrivyUserID: "did:privy:" + referrerAccountID}); err != nil {
				t.Fatalf("CreateUser(referrer): %v", err)
			}
			if err := s.CreateReferrer(referrerAccountID, referralCode); err != nil {
				t.Fatalf("CreateReferrer: %v", err)
			}
			session := &store.BillingSession{
				ID:                uniqueID("bs"),
				AccountID:         uniqueID("acct"),
				PaymentMethod:     "stripe",
				AmountMicroUSD:    25_000_000,
				ExternalID:        uniqueID("ext"),
				Status:            "pending",
				ReferralCode:      referralCode,
				ReferrerAccountID: referrerAccountID,
			}
			if err := s.CreateBillingSession(session); err != nil {
				t.Fatalf("CreateBillingSession: %v", err)
			}
			if err := s.CreateBillingSession(session); err == nil {
				t.Fatal("duplicate session ID accepted")
			}

			got, err := s.GetBillingSession(session.ID)
			if err != nil {
				t.Fatalf("GetBillingSession: %v", err)
			}
			if got.AccountID != session.AccountID || got.PaymentMethod != "stripe" ||
				got.AmountMicroUSD != 25_000_000 || got.ExternalID != session.ExternalID ||
				got.Status != "pending" || got.ReferralCode != referralCode || got.ReferrerAccountID != "" || got.CompletedAt != nil {
				t.Fatalf("stored session = %+v", got)
			}

			if err := s.CompleteBillingSession(session.ID); err != nil {
				t.Fatalf("CompleteBillingSession: %v", err)
			}
			done, err := s.GetBillingSession(session.ID)
			if err != nil || done.Status != "completed" || done.CompletedAt == nil {
				t.Fatalf("after completion = %+v, %v", done, err)
			}
			if err := s.CompleteBillingSession(session.ID); err == nil {
				t.Fatal("a session completed twice")
			}

			missing := uniqueID("bs-missing")
			if _, err := s.GetBillingSession(missing); err == nil {
				t.Fatal("unknown session returned")
			}
			if err := s.CompleteBillingSession(missing); err == nil {
				t.Fatal("unknown session completed")
			}
		})
	}
}
