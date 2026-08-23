package store

import "testing"

func TestProviderPayouts_RecordListAndSettle(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			p1 := &ProviderPayout{
				ProviderAddress: "0xProvider1",
				AmountMicroUSD:  900_000,
				Model:           "qwen3.5-9b",
				JobID:           "job-1",
			}
			p2 := &ProviderPayout{
				ProviderAddress: "0xProvider2",
				AmountMicroUSD:  450_000,
				Model:           "llama-3",
				JobID:           "job-2",
			}
			for _, payout := range []*ProviderPayout{p1, p2} {
				if err := s.RecordProviderPayout(payout); err != nil {
					t.Fatalf("RecordProviderPayout: %v", err)
				}
			}

			payouts, err := s.ListProviderPayouts()
			if err != nil {
				t.Fatalf("ListProviderPayouts: %v", err)
			}
			if len(payouts) != 2 {
				t.Fatalf("provider payouts = %d, want 2", len(payouts))
			}
			if payouts[0].ProviderAddress != "0xProvider1" || payouts[1].ProviderAddress != "0xProvider2" {
				t.Fatalf("provider payouts out of insertion order: %+v", payouts)
			}
			if payouts[0].Settled {
				t.Fatal("first payout should start unsettled")
			}

			if err := s.SettleProviderPayout(payouts[0].ID); err != nil {
				t.Fatalf("SettleProviderPayout: %v", err)
			}

			payouts, err = s.ListProviderPayouts()
			if err != nil {
				t.Fatalf("ListProviderPayouts after settle: %v", err)
			}
			if !payouts[0].Settled {
				t.Fatal("first payout should be settled")
			}
			if payouts[1].Settled {
				t.Fatal("second payout should remain unsettled")
			}

			if err := s.SettleProviderPayout(payouts[0].ID); err == nil {
				t.Fatal("expected error settling same payout twice")
			}
		})
	}
}
func TestCreditProviderAccountAtomic(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			earning := &ProviderEarning{
				AccountID:        "acct-linked",
				ProviderID:       "prov-1",
				ProviderKey:      "key-1",
				JobID:            "job-atomic",
				Model:            "qwen3.5-9b",
				AmountMicroUSD:   123_000,
				PromptTokens:     10,
				CompletionTokens: 20,
			}
			if err := s.CreditProviderAccount(earning); err != nil {
				t.Fatalf("CreditProviderAccount: %v", err)
			}

			if bal := s.GetBalance("acct-linked"); bal != 123_000 {
				t.Fatalf("balance = %d, want 123000", bal)
			}

			history := s.LedgerHistory("acct-linked")
			if len(history) != 1 {
				t.Fatalf("ledger history = %d, want 1", len(history))
			}
			if history[0].Type != LedgerPayout {
				t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
			}

			earnings, err := s.GetAccountEarnings("acct-linked", 10)
			if err != nil {
				t.Fatalf("GetAccountEarnings: %v", err)
			}
			if len(earnings) != 1 {
				t.Fatalf("earnings = %d, want 1", len(earnings))
			}
			if earnings[0].JobID != "job-atomic" {
				t.Fatalf("earning job_id = %q, want job-atomic", earnings[0].JobID)
			}
		})
	}
}
func TestCreditProviderWalletAtomic(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			payout := &ProviderPayout{
				ProviderAddress: "0xatomicwallet",
				AmountMicroUSD:  456_000,
				Model:           "llama-3",
				JobID:           "job-wallet",
			}
			if err := s.CreditProviderWallet(payout); err != nil {
				t.Fatalf("CreditProviderWallet: %v", err)
			}

			if bal := s.GetBalance("0xatomicwallet"); bal != 456_000 {
				t.Fatalf("wallet balance = %d, want 456000", bal)
			}

			history := s.LedgerHistory("0xatomicwallet")
			if len(history) != 1 {
				t.Fatalf("ledger history = %d, want 1", len(history))
			}
			if history[0].Type != LedgerPayout {
				t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
			}

			payouts, err := s.ListProviderPayouts()
			if err != nil {
				t.Fatalf("ListProviderPayouts: %v", err)
			}
			if len(payouts) != 1 {
				t.Fatalf("provider payouts = %d, want 1", len(payouts))
			}
			if payouts[0].JobID != "job-wallet" {
				t.Fatalf("payout job_id = %q, want job-wallet", payouts[0].JobID)
			}
		})
	}
}
