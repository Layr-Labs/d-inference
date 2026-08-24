package store

import (
	"strings"
	"testing"
)

// The tests in this file run the same body against every backend returned by
// storeBackends (memory always; postgres when DATABASE_URL is set), replacing
// the previous copy-pasted TestX / TestPostgresX pairs.

func TestCreateKey(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			key, err := s.CreateKey()
			if err != nil {
				t.Fatalf("CreateKey: %v", err)
			}

			if !strings.HasPrefix(key, KeyPrefix) {
				t.Errorf("key %q does not have %q prefix", key, KeyPrefix)
			}

			if !s.ValidateKey(key) {
				t.Error("created key should be valid")
			}

			if s.KeyCount() != 1 {
				t.Errorf("key count = %d, want 1", s.KeyCount())
			}
		})
	}
}

func TestCreateMultipleKeys(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			key1, _ := s.CreateKey()
			key2, _ := s.CreateKey()

			if key1 == key2 {
				t.Error("keys should be unique")
			}

			if s.KeyCount() != 2 {
				t.Errorf("key count = %d, want 2", s.KeyCount())
			}
		})
	}
}

func TestValidateKeyInvalid(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if s.ValidateKey("wrong-key") {
				t.Error("wrong key should not be valid")
			}
			if s.ValidateKey("") {
				t.Error("empty key should not be valid")
			}
		})
	}
}

func TestRevokeKey(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			key, _ := s.CreateKey()
			if !s.ValidateKey(key) {
				t.Fatal("key should be valid before revoke")
			}

			if !s.RevokeKey(key) {
				t.Error("RevokeKey should return true for existing key")
			}
			if s.ValidateKey(key) {
				t.Error("key should be invalid after revoke")
			}
			if s.KeyCount() != 0 {
				t.Errorf("key count = %d, want 0 after revoke", s.KeyCount())
			}
		})
	}
}

func TestRevokeKeyNonexistent(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if s.RevokeKey("nonexistent") {
				t.Error("RevokeKey should return false for nonexistent key")
			}
		})
	}
}

func TestRecordUsage(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			s.RecordUsage("provider-1", "consumer-key", "qwen3.5-9b", 50, 100)
			s.RecordUsage("provider-2", "consumer-key", "llama-3", 30, 200)

			records := s.UsageRecords()
			if len(records) != 2 {
				t.Fatalf("usage records = %d, want 2", len(records))
			}

			// Row order is backend-specific for same-timestamp inserts; find by
			// provider.
			var r *UsageRecord
			for i := range records {
				if records[i].ProviderID == "provider-1" {
					r = &records[i]
					break
				}
			}
			if r == nil {
				t.Fatalf("provider-1 usage record missing: %+v", records)
			}
			// Memory stores the raw consumer key; postgres stores its hash. Both
			// must attribute the record to some consumer identity.
			if r.ConsumerKey == "" {
				t.Error("consumer_key should not be empty")
			}
			if name == "memory" && r.ConsumerKey != "consumer-key" {
				t.Errorf("consumer_key = %q, want raw key on memory store", r.ConsumerKey)
			}
			if r.Model != "qwen3.5-9b" {
				t.Errorf("model = %q", r.Model)
			}
			if r.PromptTokens != 50 {
				t.Errorf("prompt_tokens = %d", r.PromptTokens)
			}
			if r.CompletionTokens != 100 {
				t.Errorf("completion_tokens = %d", r.CompletionTokens)
			}
			if r.Timestamp.IsZero() {
				t.Error("timestamp should not be zero")
			}
		})
	}
}

func TestUsageRecordsEmpty(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			records := s.UsageRecords()
			if len(records) != 0 {
				t.Errorf("usage records = %d, want 0", len(records))
			}
		})
	}
}

func TestRecordPayment(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "test payment")
			if err != nil {
				t.Fatalf("RecordPayment: %v", err)
			}
		})
	}
}

func TestRecordPaymentDuplicateTxHash(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
			if err != nil {
				t.Fatalf("first RecordPayment: %v", err)
			}

			err = s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
			if err == nil {
				t.Error("expected error for duplicate tx_hash")
			}
		})
	}
}

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
				Model:            "qwen3.5-9b-build",
				PublicModel:      "qwen3.5-9b",
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
			if earnings[0].Model != "qwen3.5-9b-build" || earnings[0].PublicModel != "qwen3.5-9b" {
				t.Fatalf("earning model identity = %q/%q, want concrete/public pair", earnings[0].Model, earnings[0].PublicModel)
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
