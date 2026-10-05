package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Account erasure (RequestAccountErasure) is the writer of deleted_at. These
// tests set deleted_at alone, with nothing else changed, and prove that every
// live read hides the row. erasure_soft_delete_reads_test.go in
// coordinator/tests/store/contracts runs the same reads after the real writer
// on both backends.

// softDelete marks one row of table deleted. key matches account_id for
// users, id for api_keys and providers, and token_hash for provider_tokens.
func softDelete(t *testing.T, s *postgresFixture, table, key string) {
	t.Helper()
	column := map[string]string{"users": "account_id", "api_keys": "id", "providers": "id", "provider_tokens": "token_hash"}[table]
	if column == "" {
		t.Fatalf("unknown table %s", table)
	}
	tag, err := s.pool.Exec(context.Background(),
		`UPDATE `+table+` SET deleted_at = NOW() WHERE `+column+` = $1`, key)
	if err != nil || tag.RowsAffected() != 1 {
		t.Fatalf("soft-delete %s %s: %d rows, %v", table, key, tag.RowsAffected(), err)
	}
}

func TestSoftDeletedUserIsHidden(t *testing.T) {
	s := testPostgresStore(t)
	account := uniqueID("acct-gone")
	privy := uniqueID("did:privy:gone")
	email := uniqueID("gone") + "@example.com"
	stripe := uniqueID("acct_stripe")
	if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: privy, Email: email}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(account, stripe, "ready", "US", "bank", "1234", false); err != nil {
		t.Fatal(err)
	}
	promotions, _ := store.As[store.ModelTokenPromotionStore](s)
	now := time.Now().UTC().Truncate(time.Second)
	model := uniqueID("promo/model")
	if err := promotions.PutModelTokenPromotion(store.ModelTokenPromotion{ModelID: model, Tokens: 10, ClaimStartsAt: now.Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(now.Add(time.Hour)), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 10, Enabled: true}); err != nil {
		t.Fatal(err)
	}

	softDelete(t, s, "users", account)

	if _, err := s.GetUserByAccountID(account); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("GetUserByAccountID: %v, want ErrNotFound", err)
	}
	if _, err := s.GetUserByPrivyID(privy); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("GetUserByPrivyID: %v, want ErrNotFound", err)
	}
	if u, err := s.GetUserByStripeAccount(stripe); err == nil {
		t.Fatalf("GetUserByStripeAccount returned %+v", u)
	}
	if u, err := s.GetUserByEmail(email); err == nil {
		t.Fatalf("GetUserByEmail returned %+v", u)
	}
	if _, err := promotions.ClaimModelTokenPromotion(account, model, now); !errors.Is(err, store.ErrPromotionIneligible) {
		t.Fatalf("ClaimModelTokenPromotion: %v, want ErrPromotionIneligible", err)
	}

	// The Privy ID is free again for a new live account, and only one
	// live account may hold it.
	again := uniqueID("acct-again")
	if err := s.CreateUser(&store.User{AccountID: again, PrivyUserID: privy}); err != nil {
		t.Fatalf("re-signup with the Privy ID of a deleted user: %v", err)
	}
	if u, err := s.GetUserByPrivyID(privy); err != nil || u.AccountID != again {
		t.Fatalf("GetUserByPrivyID after re-signup = %+v, %v", u, err)
	}
	if err := s.CreateUser(&store.User{AccountID: uniqueID("acct-dup"), PrivyUserID: privy}); err == nil {
		t.Fatal("two live users hold the same Privy ID")
	}
}

func TestSoftDeletedAPIKeyIsHidden(t *testing.T) {
	s := testPostgresStore(t)
	account := uniqueID("acct-keys")
	raw, gone, err := s.CreateAPIKey(account, store.APIKeyCreate{Name: "gone"})
	if err != nil {
		t.Fatal(err)
	}
	_, live, err := s.CreateAPIKey(account, store.APIKeyCreate{Name: "live"})
	if err != nil {
		t.Fatal(err)
	}

	softDelete(t, s, "api_keys", gone.ID)

	if got := s.GetKeyAccount(raw); got != "" {
		t.Fatalf("GetKeyAccount = %q, want empty", got)
	}
	if k, err := s.AuthenticateKey(raw); err == nil {
		t.Fatalf("AuthenticateKey returned %+v", k)
	}
	if k, err := s.GetAPIKeyByID(account, gone.ID); err == nil {
		t.Fatalf("GetAPIKeyByID returned %+v", k)
	}
	if k, err := s.UpdateAPIKey(account, gone.ID, *gone); err == nil {
		t.Fatalf("UpdateAPIKey returned %+v", k)
	}
	if _, k, err := s.RotateAPIKey(account, gone.ID); err == nil {
		t.Fatalf("RotateAPIKey returned %+v", k)
	}
	keys, err := s.ListAPIKeys(account)
	if err != nil || len(keys) != 1 || keys[0].ID != live.ID {
		t.Fatalf("ListAPIKeys = %+v, %v; want only the live key", keys, err)
	}
}

func TestSoftDeletedProviderTokenIsHidden(t *testing.T) {
	s := testPostgresStore(t)
	raw := uniqueID("provider-token")
	if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(raw), AccountID: uniqueID("acct"), Label: "mac", Active: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetProviderToken(raw); err != nil {
		t.Fatalf("GetProviderToken before delete: %v", err)
	}
	softDelete(t, s, "provider_tokens", store.HashKey(raw))
	if pt, err := s.GetProviderToken(raw); err == nil {
		t.Fatalf("GetProviderToken returned %+v", pt)
	}
}

func TestSoftDeletedProviderIsHidden(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	account := uniqueID("acct-providers")
	serial := uniqueID("serial")
	seKey := uniqueID("se")
	location := &store.ProviderLocation{City: "Gone City", Region: "Region", RegionCode: "R", Country: "Country", CountryCode: "CC"}
	live := store.ProviderRecord{ID: uniqueID("live"), AccountID: account, SerialNumber: serial, SEPublicKey: seKey,
		MDACertChain: []byte(`["live"]`), Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-2 * time.Hour)}
	gone := store.ProviderRecord{ID: uniqueID("gone"), AccountID: account, SerialNumber: serial, SEPublicKey: seKey,
		MDACertChain: []byte(`["gone"]`), Location: location, Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-time.Hour)}
	for _, p := range []store.ProviderRecord{live, gone} {
		if err := s.UpsertProvider(ctx, p); err != nil {
			t.Fatal(err)
		}
	}
	consumerLocation := &store.ProviderLocation{City: "Origin", Region: "Region", RegionCode: "R", Country: "Country", CountryCode: "CC"}
	s.RecordUsage(store.UsageRecord{ProviderID: gone.ID, ConsumerKey: uniqueID("consumer"), Model: "m", RequestID: uniqueID("req"),
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
		t.Fatal("fixture: no usage flow to the provider before delete")
	}

	softDelete(t, s, "providers", gone.ID)

	if p, err := s.GetProviderRecord(ctx, gone.ID); err == nil {
		t.Fatalf("GetProviderRecord returned %+v", p)
	}
	if _, err := s.GetProviderRecord(ctx, live.ID); err != nil {
		t.Fatalf("GetProviderRecord of the live record: %v", err)
	}
	if chain, err := s.GetMDAChainBySerial(ctx, serial); err != nil || string(chain) != `["live"]` {
		t.Fatalf("GetMDAChainBySerial = %s, %v; want the live chain", chain, err)
	}
	list, err := s.ListProvidersByAccount(ctx, account)
	if err != nil || len(list) != 1 || list[0].ID != live.ID {
		t.Fatalf("ListProvidersByAccount = %+v, %v; want only the live record", list, err)
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
	softDelete(t, s, "providers", live.ID)
	if p, err := s.GetProviderForRestore(ctx, serial, seKey, nil); err != nil || p != nil {
		t.Fatalf("GetProviderForRestore restored a deleted record: %+v, %v", p, err)
	}
}

func TestSoftDeletedProviderIsNotContinuityHistory(t *testing.T) {
	backend := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	inventory, _ := store.As[store.MachineInventoryStore](backend)
	keys, _ := store.As[store.AppAttestShadowStore](backend)
	continuity, _ := store.As[store.MachineOperationalStore](backend)
	account := uniqueID("owner")
	appKey := uniqueID("apple")
	original, reconnect := uniqueID("original"), uniqueID("reconnect")
	if _, err := keys.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: appKey, AccountID: account}); err != nil {
		t.Fatal(err)
	}
	if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: original, AccountID: account, At: now, SEKey: uniqueID("se"), VerifiedAppAttestKey: appKey}); err != nil {
		t.Fatal(err)
	}
	prior := store.ProviderRecord{ID: original, AccountID: account, Hardware: []byte(`{}`), Models: []byte(`[]`), LastSeen: now.Add(-time.Minute)}
	if err := backend.UpsertProvider(ctx, prior); err != nil {
		t.Fatal(err)
	}
	if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: reconnect, AccountID: account, At: now, SEKey: uniqueID("se"), VerifiedAppAttestKey: appKey}); err != nil {
		t.Fatal(err)
	}
	got, err := continuity.ResolveMachineContinuity(ctx, reconnect, account, appKey, nil)
	if err != nil || got.Previous == nil || got.Previous.ID != prior.ID {
		t.Fatalf("fixture: continuity before delete = %+v, %v", got, err)
	}

	softDelete(t, backend, "providers", prior.ID)

	got, err = continuity.ResolveMachineContinuity(ctx, reconnect, account, appKey, nil)
	if err != nil || got.Previous != nil {
		t.Fatalf("continuity returned a deleted provider record: %+v, %v", got.Previous, err)
	}
}

func TestSoftDeletedProviderIsNotBackfilledPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	gone := uniqueID("historical-gone")
	if err := s.UpsertProvider(ctx, store.ProviderRecord{ID: gone, AccountID: "owner", LastSeen: time.Now().UTC().Add(-10 * time.Minute), Hardware: []byte(`{}`), Models: []byte(`[]`)}); err != nil {
		t.Fatal(err)
	}
	softDelete(t, s, "providers", gone)
	if _, err := s.BackfillMachineInventory(ctx, 100); err != nil {
		t.Fatal(err)
	}
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM darkbloom_machine_sessions WHERE session_id=$1)`, gone).Scan(&exists); err != nil || exists {
		t.Fatalf("backfill recorded a deleted provider: %v %v", exists, err)
	}
}
