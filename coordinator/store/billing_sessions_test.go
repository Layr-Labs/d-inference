package store

import "testing"

func TestBillingSessionLifecycleBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			session := &BillingSession{
				ID:             uniqueID("bs"),
				AccountID:      uniqueID("acct"),
				PaymentMethod:  "stripe",
				AmountMicroUSD: 25_000_000,
				ExternalID:     uniqueID("ext"),
				Status:         "pending",
				ReferralCode:   "REF-1",
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
				got.Status != "pending" || got.ReferralCode != "REF-1" || got.CompletedAt != nil {
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
