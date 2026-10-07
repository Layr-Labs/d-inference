package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// RequestAccountErasure soft deletes the account: the user, its API keys,
// its provider tokens and its providers get deleted_at. These tests run that
// writer on every backend and check the same live reads as
// coordinator/tests/store/postgres/soft_delete_reads_test.go: each one hides
// the soft-deleted rows and still returns the other account's rows.

func TestErasureHidesSoftDeletedUser(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Second)
			a := erasurefixture.SeedAccount(t, s)
			promotions, ok := store.As[store.ModelTokenPromotionStore](s)
			if !ok {
				t.Fatal("no model token promotion store")
			}
			model := erasurefixture.UniqueID("promo/model")
			if err := promotions.PutModelTokenPromotion(store.ModelTokenPromotion{ModelID: model, Tokens: 10, ClaimStartsAt: now.Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(now.Add(time.Hour)), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 10, Enabled: true}); err != nil {
				t.Fatal(err)
			}

			erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)

			if _, err := s.GetUserByAccountID(a.AccountID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("GetUserByAccountID: %v, want ErrNotFound", err)
			}
			if _, err := s.GetUserByPrivyID(a.PrivyID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("GetUserByPrivyID: %v, want ErrNotFound", err)
			}
			if u, err := s.GetUserByStripeAccount(a.Stripe); err == nil {
				t.Fatalf("GetUserByStripeAccount returned %+v", u)
			}
			if u, err := s.GetUserByEmail(a.Email); err == nil {
				t.Fatalf("GetUserByEmail returned %+v", u)
			}
			if _, err := promotions.ClaimModelTokenPromotion(a.AccountID, model, now); !errors.Is(err, store.ErrPromotionIneligible) {
				t.Fatalf("ClaimModelTokenPromotion: %v, want ErrPromotionIneligible", err)
			}

			// The Privy ID is free again for a new live account, and only one
			// live account may hold it.
			again := erasurefixture.UniqueID("acct-again")
			if err := s.CreateUser(&store.User{AccountID: again, PrivyUserID: a.PrivyID}); err != nil {
				t.Fatalf("re-signup with the Privy ID of a deleted user: %v", err)
			}
			if u, err := s.GetUserByPrivyID(a.PrivyID); err != nil || u.AccountID != again {
				t.Fatalf("GetUserByPrivyID after re-signup = %+v, %v", u, err)
			}
			if err := s.CreateUser(&store.User{AccountID: erasurefixture.UniqueID("acct-dup"), PrivyUserID: a.PrivyID}); err == nil {
				t.Fatal("two live users hold the same Privy ID")
			}
		})
	}
}

func TestErasureHidesSoftDeletedAPIKeys(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			a := erasurefixture.SeedAccount(t, s)
			_, gone, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "second"})
			if err != nil {
				t.Fatal(err)
			}
			other := erasurefixture.UniqueID("acct-other")
			otherRaw, otherKey, err := s.CreateAPIKey(other, store.APIKeyCreate{Name: "other"})
			if err != nil {
				t.Fatal(err)
			}

			erasurefixture.PlanAndConfirm(t, s, a, time.Now().UTC(), time.Hour)

			if got := s.GetKeyAccount(a.RawKey); got != "" {
				t.Fatalf("GetKeyAccount = %q, want empty", got)
			}
			if k, err := s.AuthenticateKey(a.RawKey); err == nil {
				t.Fatalf("AuthenticateKey returned %+v", k)
			}
			if k, err := s.GetAPIKeyByID(a.AccountID, gone.ID); err == nil {
				t.Fatalf("GetAPIKeyByID returned %+v", k)
			}
			if k, err := s.UpdateAPIKey(a.AccountID, gone.ID, *gone); err == nil {
				t.Fatalf("UpdateAPIKey returned %+v", k)
			}
			if _, k, err := s.RotateAPIKey(a.AccountID, gone.ID); err == nil {
				t.Fatalf("RotateAPIKey returned %+v", k)
			}
			if keys, err := s.ListAPIKeys(a.AccountID); err != nil || len(keys) != 0 {
				t.Fatalf("ListAPIKeys = %+v, %v; want none", keys, err)
			}
			if got := s.GetKeyAccount(otherRaw); got != other {
				t.Fatalf("GetKeyAccount of another account's key = %q", got)
			}
			if keys, err := s.ListAPIKeys(other); err != nil || len(keys) != 1 || keys[0].ID != otherKey.ID {
				t.Fatalf("ListAPIKeys of another account = %+v, %v", keys, err)
			}
		})
	}
}

func TestErasureHidesSoftDeletedProviderToken(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			a := erasurefixture.SeedAccount(t, s)
			otherRaw := erasurefixture.UniqueID("provider-token")
			if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(otherRaw), AccountID: erasurefixture.UniqueID("acct-other"), Label: "mac", Active: true}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.GetProviderToken(a.ProviderToken); err != nil {
				t.Fatalf("GetProviderToken before erasure: %v", err)
			}

			erasurefixture.PlanAndConfirm(t, s, a, time.Now().UTC(), time.Hour)

			if pt, err := s.GetProviderToken(a.ProviderToken); err == nil {
				t.Fatalf("GetProviderToken returned %+v", pt)
			}
			if _, err := s.GetProviderToken(otherRaw); err != nil {
				t.Fatalf("GetProviderToken of another account: %v", err)
			}
		})
	}
}

func TestErasureHidesSoftDeletedProviders(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			a := erasurefixture.SeedAccount(t, s)
			other := erasurefixture.UniqueID("acct-other")
			serial, seKey := erasurefixture.UniqueID("serial"), erasurefixture.UniqueID("se")
			location := &store.ProviderLocation{City: erasurefixture.UniqueID("Gone City"), Region: "Region", RegionCode: "R", Country: "Country", CountryCode: "CC"}
			// gone belongs to the erased account; live is the same Mac, now
			// linked to another account.
			gone := store.ProviderRecord{ID: erasurefixture.UniqueID("gone"), AccountID: a.AccountID, SerialNumber: serial, SEPublicKey: seKey,
				MDACertChain: []byte(`["gone"]`), Location: location, Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-time.Hour)}
			live := store.ProviderRecord{ID: erasurefixture.UniqueID("live"), AccountID: other, SerialNumber: serial, SEPublicKey: seKey,
				MDACertChain: []byte(`["live"]`), Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-2 * time.Hour)}
			for _, p := range []store.ProviderRecord{gone, live} {
				if err := s.UpsertProvider(ctx, p); err != nil {
					t.Fatal(err)
				}
			}
			consumerLocation := &store.ProviderLocation{City: "Origin", Region: "Region", RegionCode: "R", Country: "Country", CountryCode: "CC"}
			s.RecordUsage(store.UsageRecord{ProviderID: gone.ID, ConsumerKey: erasurefixture.UniqueID("consumer"), Model: "m", RequestID: erasurefixture.UniqueID("req"),
				PromptTokens: 1, CompletionTokens: 1, RequestLocation: consumerLocation})
			flowsTo := func() int {
				t.Helper()
				buckets, err := s.UsageFlowBuckets(now.Add(-24*time.Hour), nil)
				if err != nil {
					t.Fatal(err)
				}
				n := 0
				for _, b := range buckets {
					if b.ProviderCity == location.City {
						n++
					}
				}
				return n
			}
			if flowsTo() != 1 {
				t.Fatal("fixture: no usage flow to the provider before erasure")
			}
			if chain, err := s.GetMDAChainBySerial(ctx, serial); err != nil || string(chain) != `["gone"]` {
				t.Fatalf("fixture: GetMDAChainBySerial = %s, %v; want the newer record's chain", chain, err)
			}

			erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)

			for _, id := range []string{gone.ID, a.ProviderID} {
				if p, err := s.GetProviderRecord(ctx, id); err == nil {
					t.Fatalf("GetProviderRecord(%s) returned %+v", id, p)
				}
			}
			if _, err := s.GetProviderRecord(ctx, live.ID); err != nil {
				t.Fatalf("GetProviderRecord of another account's record: %v", err)
			}
			if chain, err := s.GetMDAChainBySerial(ctx, serial); err != nil || string(chain) != `["live"]` {
				t.Fatalf("GetMDAChainBySerial = %s, %v; want the live chain", chain, err)
			}
			if list, err := s.ListProvidersByAccount(ctx, a.AccountID); err != nil || len(list) != 0 {
				t.Fatalf("ListProvidersByAccount = %+v, %v; want none", list, err)
			}
			for _, lookup := range []struct{ serial, seKey string }{{serial, ""}, {"", seKey}} {
				p, err := s.GetProviderForRestore(ctx, lookup.serial, lookup.seKey, nil)
				if err != nil || p == nil || p.ID != live.ID {
					t.Fatalf("GetProviderForRestore(%q, %q) = %+v, %v; want the live record", lookup.serial, lookup.seKey, p, err)
				}
			}
			if n := flowsTo(); n != 0 {
				t.Fatalf("usage flows still show the deleted provider's location (%d buckets)", n)
			}
			// A deleted record is never restored, even when it is the only match.
			if p, err := s.GetProviderForRestore(ctx, serial, seKey, []string{live.ID}); err != nil || p != nil {
				t.Fatalf("GetProviderForRestore restored a deleted record: %+v, %v", p, err)
			}
		})
	}
}

func TestErasureHidesSoftDeletedProviderFromContinuity(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			inventory, _ := store.As[store.MachineInventoryStore](s)
			keys, _ := store.As[store.AppAttestShadowStore](s)
			continuity, _ := store.As[store.MachineOperationalStore](s)
			if inventory == nil || keys == nil || continuity == nil {
				t.Fatal("backend lacks machine inventory, App Attest or continuity capabilities")
			}
			a := erasurefixture.SeedAccount(t, s)
			appKey := erasurefixture.UniqueID("apple")
			original, reconnect := erasurefixture.UniqueID("original"), erasurefixture.UniqueID("reconnect")
			if _, err := keys.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: appKey, AccountID: a.AccountID}); err != nil {
				t.Fatal(err)
			}
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: original, AccountID: a.AccountID, At: now, SEKey: erasurefixture.UniqueID("se"), VerifiedAppAttestKey: appKey}); err != nil {
				t.Fatal(err)
			}
			prior := store.ProviderRecord{ID: original, AccountID: a.AccountID, Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-time.Minute)}
			if err := s.UpsertProvider(ctx, prior); err != nil {
				t.Fatal(err)
			}
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: reconnect, AccountID: a.AccountID, At: now, SEKey: erasurefixture.UniqueID("se"), VerifiedAppAttestKey: appKey}); err != nil {
				t.Fatal(err)
			}
			got, err := continuity.ResolveMachineContinuity(ctx, reconnect, a.AccountID, appKey, nil)
			if err != nil || got.Previous == nil || got.Previous.ID != prior.ID {
				t.Fatalf("fixture: continuity before erasure = %+v, %v", got, err)
			}

			erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)

			got, err = continuity.ResolveMachineContinuity(ctx, reconnect, a.AccountID, appKey, nil)
			if err != nil || got.Previous != nil {
				t.Fatalf("continuity returned a deleted provider record: %+v, %v", got.Previous, err)
			}
		})
	}
}
