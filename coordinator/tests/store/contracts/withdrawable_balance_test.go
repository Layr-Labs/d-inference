package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestWithdrawableBalance_CreditIsNotWithdrawable(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_ = st.Credit("acct-1", 10_000_000, store.LedgerStripeDeposit, "stripe:123")

			if bal := st.GetBalance("acct-1"); bal != 10_000_000 {
				t.Errorf("balance = %d, want 10_000_000", bal)
			}
			if w := st.GetWithdrawableBalance("acct-1"); w != 0 {
				t.Errorf("withdrawable = %d, want 0 (Stripe deposit is not withdrawable)", w)
			}
		})
	}
}

func TestWithdrawableBalance_CreditWithdrawableIncrementsBoth(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_ = st.CreditWithdrawable("acct-1", 10_000_000, store.LedgerPayout, "job-1")

			if bal := st.GetBalance("acct-1"); bal != 10_000_000 {
				t.Errorf("balance = %d, want 10_000_000", bal)
			}
			if w := st.GetWithdrawableBalance("acct-1"); w != 10_000_000 {
				t.Errorf("withdrawable = %d, want 10_000_000", w)
			}
		})
	}
}

func TestWithdrawableBalance_DebitConsumesCreditsFirst(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_ = st.Credit("acct-1", 20_000_000, store.LedgerStripeDeposit, "stripe:1")
			_ = st.CreditWithdrawable("acct-1", 30_000_000, store.LedgerPayout, "job-1")

			if bal := st.GetBalance("acct-1"); bal != 50_000_000 {
				t.Fatalf("balance = %d, want 50_000_000", bal)
			}
			if w := st.GetWithdrawableBalance("acct-1"); w != 30_000_000 {
				t.Fatalf("withdrawable = %d, want 30_000_000", w)
			}

			_ = st.Debit("acct-1", 15_000_000, store.LedgerCharge, "req-1")
			if bal := st.GetBalance("acct-1"); bal != 35_000_000 {
				t.Errorf("after $15 charge: balance = %d, want 35_000_000", bal)
			}
			if w := st.GetWithdrawableBalance("acct-1"); w != 30_000_000 {
				t.Errorf("after $15 charge: withdrawable = %d, want 30_000_000 (credits consumed first)", w)
			}

			_ = st.Debit("acct-1", 10_000_000, store.LedgerCharge, "req-2")
			if bal := st.GetBalance("acct-1"); bal != 25_000_000 {
				t.Errorf("after $10 charge: balance = %d, want 25_000_000", bal)
			}
			if w := st.GetWithdrawableBalance("acct-1"); w != 25_000_000 {
				t.Errorf("after $10 charge: withdrawable = %d, want 25_000_000", w)
			}
		})
	}
}

func TestWithdrawableBalance_DebitAllEarnings(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_ = st.CreditWithdrawable("acct-1", 50_000_000, store.LedgerPayout, "job-1")

			_ = st.Debit("acct-1", 25_000_000, store.LedgerCharge, "req-1")
			if w := st.GetWithdrawableBalance("acct-1"); w != 25_000_000 {
				t.Errorf("withdrawable = %d, want 25_000_000", w)
			}

			_ = st.Debit("acct-1", 25_000_000, store.LedgerCharge, "req-2")
			if w := st.GetWithdrawableBalance("acct-1"); w != 0 {
				t.Errorf("withdrawable = %d, want 0", w)
			}
		})
	}
}

func TestWithdrawableBalance_ProviderEarningIsWithdrawable(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			u := &store.User{AccountID: "acct-provider", PrivyUserID: "did:privy:p1", Email: "p@test.com"}
			_ = st.CreateUser(u)

			_ = st.CreditProviderAccount(&store.ProviderEarning{
				AccountID:      "acct-provider",
				ProviderID:     "prov-1",
				ProviderKey:    "key-1",
				JobID:          "job-1",
				Model:          "test-model",
				AmountMicroUSD: 5_000_000,
			})

			if w := st.GetWithdrawableBalance("acct-provider"); w != 5_000_000 {
				t.Errorf("provider earning should be withdrawable: got %d, want 5_000_000", w)
			}
		})
	}
}

func TestWithdrawableBalance_GetUserByEmail(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_ = st.CreateUser(&store.User{
				AccountID:   "acct-email-1",
				PrivyUserID: "did:privy:e1",
				Email:       "Alice@Example.COM",
			})

			u, err := st.GetUserByEmail("alice@example.com")
			if err != nil {
				t.Fatalf("lookup by lowercase email failed: %v", err)
			}
			if u.AccountID != "acct-email-1" {
				t.Errorf("got accountID %q", u.AccountID)
			}

			_, err = st.GetUserByEmail("nobody@example.com")
			if err == nil {
				t.Error("expected error for unknown email")
			}
		})
	}
}

func TestWithdrawableBalance_ReferralRewardIsWithdrawable(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {

			// Directly test that CreditWithdrawable with LedgerReferralReward works
			_ = st.CreditWithdrawable("referrer-acct", 1_000_000, store.LedgerReferralReward, "job-1")

			if w := st.GetWithdrawableBalance("referrer-acct"); w != 1_000_000 {
				t.Errorf("referral reward should be withdrawable: got %d, want 1_000_000", w)
			}
			if bal := st.GetBalance("referrer-acct"); bal != 1_000_000 {
				t.Errorf("balance = %d, want 1_000_000", bal)
			}
		})
	}
}
