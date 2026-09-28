package store

import (
	"strings"
	"testing"
)

// The tests in this file run the same body against every backend returned by
// storeBackends (memory always; postgres when DATABASE_URL is set), replacing
// the previous copy-pasted TestX / TestPostgresX pairs.

func TestCreateAPIKeyIsPrefixedAndCounted(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct")
			key, _, err := s.CreateAPIKey(acct, APIKeyCreate{})
			if err != nil {
				t.Fatalf("CreateAPIKey: %v", err)
			}

			if !strings.HasPrefix(key, KeyPrefix) {
				t.Errorf("key %q does not have %q prefix", key, KeyPrefix)
			}

			if !keyAuthenticates(s, key) {
				t.Error("created key should be valid")
			}

			if n := activeKeyCount(t, s, acct); n != 1 {
				t.Errorf("key count = %d, want 1", n)
			}
		})
	}
}

func TestCreateAPIKeyIsUnique(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct")
			key1, _, _ := s.CreateAPIKey(acct, APIKeyCreate{})
			key2, _, _ := s.CreateAPIKey(acct, APIKeyCreate{})

			if key1 == key2 {
				t.Error("keys should be unique")
			}

			if n := activeKeyCount(t, s, acct); n != 2 {
				t.Errorf("key count = %d, want 2", n)
			}
		})
	}
}

func TestAuthenticateKeyRejectsUnknown(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if keyAuthenticates(s, "wrong-key") {
				t.Error("wrong key should not be valid")
			}
			if keyAuthenticates(s, "") {
				t.Error("empty key should not be valid")
			}
		})
	}
}

func TestRevokeKey(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct")
			key, _, _ := s.CreateAPIKey(acct, APIKeyCreate{})
			if !keyAuthenticates(s, key) {
				t.Fatal("key should be valid before revoke")
			}

			if !s.RevokeKey(key) {
				t.Error("RevokeKey should return true for existing key")
			}
			if keyAuthenticates(s, key) {
				t.Error("key should be invalid after revoke")
			}
			if n := activeKeyCount(t, s, acct); n != 0 {
				t.Errorf("key count = %d, want 0 after revoke", n)
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
			s.RecordUsage(UsageRecord{ProviderID: "provider-1", ConsumerKey: "consumer-key", Model: "qwen3.5-9b", PromptTokens: 50, CompletionTokens: 100})
			s.RecordUsage(UsageRecord{ProviderID: "provider-2", ConsumerKey: "consumer-key", Model: "llama-3", PromptTokens: 30, CompletionTokens: 200})

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
