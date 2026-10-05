package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// The api_keys lifecycle on every backend: memory always, Postgres (the
// sqlc queries) when DATABASE_URL is set.
func TestAPIKeyLifecycleOnEveryBackend(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("acct-keys")
			limit := int64(7_000_000)
			rpm := int64(60)
			expires := time.Now().UTC().Add(time.Hour).Truncate(time.Microsecond)
			raw, rec, err := s.CreateAPIKey(account, store.APIKeyCreate{
				Name: "prod", LimitMicroUSD: &limit, RPMLimit: &rpm, LimitReset: store.KeyResetWeekly,
				AllowedModels: []string{"m1", "m2"}, ExpiresAt: &expires,
			})
			if err != nil {
				t.Fatalf("CreateAPIKey: %v", err)
			}
			if got := s.GetKeyAccount(raw); got != account {
				t.Fatalf("GetKeyAccount = %q, want %q", got, account)
			}

			got, err := s.GetAPIKeyByID(account, rec.ID)
			if err != nil {
				t.Fatalf("GetAPIKeyByID: %v", err)
			}
			if got.Name != "prod" || got.Label != rec.Label || got.KeyHash != rec.KeyHash ||
				got.LimitMicroUSD == nil || *got.LimitMicroUSD != limit ||
				got.RPMLimit == nil || *got.RPMLimit != rpm || got.ITPMLimit != nil ||
				got.LimitReset != store.KeyResetWeekly || len(got.AllowedModels) != 2 ||
				got.ExpiresAt == nil || !got.ExpiresAt.Equal(expires) || got.LastUsedAt != nil {
				t.Fatalf("GetAPIKeyByID = %+v", got)
			}
			if _, err := s.GetAPIKeyByID(uniqueID("other"), rec.ID); err == nil {
				t.Fatal("GetAPIKeyByID for another owner must fail")
			}

			used := time.Now().UTC().Truncate(time.Microsecond)
			s.TouchAPIKey(rec.ID, used)
			if got, err := s.GetAPIKeyByID(account, rec.ID); err != nil || got.LastUsedAt == nil || !got.LastUsedAt.Equal(used) {
				t.Fatalf("after TouchAPIKey: %+v, %v", got, err)
			}

			s.RecordUsage(store.UsageRecord{ProviderID: "prov", ConsumerKey: account, KeyID: rec.ID, Model: "model",
				RequestID: uniqueID("req"), PromptTokens: 1, CompletionTokens: 1, CostMicroUSD: 2_500_000})
			if spend := s.KeySpendSince(rec.ID, time.Time{}); spend != 2_500_000 {
				t.Fatalf("lifetime KeySpendSince = %d, want 2500000", spend)
			}
			if spend := s.KeySpendSince(rec.ID, time.Now().UTC().AddDate(0, 0, 1)); spend != 0 {
				t.Fatalf("future KeySpendSince = %d, want 0", spend)
			}

			mutable := *got
			mutable.Name = "renamed"
			mutable.LimitMicroUSD = nil
			mutable.RPMLimit = nil
			mutable.LimitReset = store.KeyResetNone
			mutable.AllowedModels = nil
			mutable.Disabled = true
			updated, err := s.UpdateAPIKey(account, rec.ID, mutable)
			if err != nil {
				t.Fatalf("UpdateAPIKey: %v", err)
			}
			if updated.Name != "renamed" || updated.LimitMicroUSD != nil || updated.RPMLimit != nil ||
				updated.LimitReset != store.KeyResetNone || updated.AllowedModels != nil || !updated.Disabled {
				t.Fatalf("UpdateAPIKey = %+v", updated)
			}
			if _, err := s.UpdateAPIKey(uniqueID("other"), rec.ID, mutable); err == nil {
				t.Fatal("UpdateAPIKey for another owner must fail")
			}
			if _, err := s.AuthenticateKey(raw); err == nil {
				t.Fatal("a disabled key must not authenticate")
			}

			newRaw, rotated, err := s.RotateAPIKey(account, rec.ID)
			if err != nil {
				t.Fatalf("RotateAPIKey: %v", err)
			}
			if rotated.ID == rec.ID || newRaw == raw || rotated.Name != "renamed" || !rotated.Disabled {
				t.Fatalf("RotateAPIKey = %+v", rotated)
			}
			if _, _, err := s.RotateAPIKey(account, rec.ID); err == nil {
				t.Fatal("rotating the replaced id must fail")
			}
			keys, err := s.ListAPIKeys(account)
			if err != nil || len(keys) != 1 || keys[0].ID != rotated.ID {
				t.Fatalf("ListAPIKeys = %+v, %v; want only the rotated key", keys, err)
			}

			if err := s.RevokeAPIKeyByID(uniqueID("other"), rotated.ID); err == nil {
				t.Fatal("RevokeAPIKeyByID for another owner must fail")
			}
			if err := s.RevokeAPIKeyByID(account, rotated.ID); err != nil {
				t.Fatalf("RevokeAPIKeyByID: %v", err)
			}
			if keys, err := s.ListAPIKeys(account); err != nil || keys == nil || len(keys) != 0 {
				t.Fatalf("ListAPIKeys after revoke = %#v, %v; want an empty list", keys, err)
			}
			if err := s.RevokeAPIKeyByID(account, rotated.ID); err == nil {
				t.Fatal("revoking a deleted key must fail")
			}
		})
	}
}
