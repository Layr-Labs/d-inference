package store

import (
	"testing"
	"time"
)

// TestAPIKeyLifecycleBackends covers one key's lifecycle on both backends:
// owner lookup, last-used time, spend, and owner-scoped deletion.
func TestAPIKeyLifecycleBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			owner := uniqueID("acct")
			raw, err := s.CreateKeyForAccount(owner)
			if err != nil || raw == "" {
				t.Fatalf("CreateKeyForAccount = %q, %v", raw, err)
			}
			if got := s.GetKeyAccount(raw); got != owner {
				t.Fatalf("GetKeyAccount = %q, want %q", got, owner)
			}
			if got := s.GetKeyAccount(uniqueID("unknown-key")); got != "" {
				t.Fatalf("GetKeyAccount(unknown) = %q, want empty", got)
			}

			keys, err := s.ListAPIKeys(owner)
			if err != nil || len(keys) != 1 {
				t.Fatalf("ListAPIKeys = %+v, %v", keys, err)
			}
			id := keys[0].ID

			usedAt := time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
			s.TouchAPIKey(id, usedAt)
			s.TouchAPIKey(uniqueID("missing-id"), usedAt) // unknown IDs are ignored
			s.TouchAPIKey("", usedAt)
			touched, err := s.GetAPIKeyByID(owner, id)
			if err != nil || touched.LastUsedAt == nil || !touched.LastUsedAt.Equal(usedAt) {
				t.Fatalf("after TouchAPIKey = %+v, %v; want last used %v", touched, err, usedAt)
			}

			s.RecordUsage(UsageRecord{ProviderID: "prov", ConsumerKey: owner, KeyID: id, Model: "model",
				RequestID: uniqueID("req"), PromptTokens: 10, CompletionTokens: 5, CostMicroUSD: 1_250_000})
			s.RecordUsage(UsageRecord{ProviderID: "prov", ConsumerKey: owner, KeyID: id, Model: "model",
				RequestID: uniqueID("req"), PromptTokens: 1, CompletionTokens: 1, CostMicroUSD: 250_000})
			if got := s.KeySpendSince(id, time.Time{}); got != 1_500_000 {
				t.Fatalf("lifetime spend = %d, want 1500000", got)
			}
			if got := s.KeySpendSince(id, time.Now().UTC().Add(48*time.Hour)); got != 0 {
				t.Fatalf("spend since a future time = %d, want 0", got)
			}
			if got := s.KeySpendSince("", time.Time{}); got != 0 {
				t.Fatalf("spend for an empty key ID = %d, want 0", got)
			}

			if err := s.RevokeAPIKeyByID(uniqueID("other-acct"), id); err == nil {
				t.Fatal("another account deleted the key")
			}
			if err := s.RevokeAPIKeyByID(owner, id); err != nil {
				t.Fatalf("RevokeAPIKeyByID: %v", err)
			}
			if got := s.GetKeyAccount(raw); got != "" {
				t.Fatalf("deleted key still maps to %q", got)
			}
			if err := s.RevokeAPIKeyByID(owner, id); err == nil {
				t.Fatal("deleted key deleted again")
			}
		})
	}
}
