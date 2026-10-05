package store_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/legacymdm"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLegacyMDMStartupDrainsHistoricalInventory(t *testing.T) {
	st := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	seed := func(id string, bound bool) store.ProviderRecord {
		t.Helper()
		p := legacyMDMFixture(t, st, id, false)
		p.PublicKey = "endpoint-" + id
		p.LastSeen = time.Now().Add(-time.Hour)
		result := attestation.VerificationResult{Valid: true, PublicKey: p.SEPublicKey, EncryptionPublicKey: p.PublicKey}
		if !bound {
			result.EncryptionPublicKey = "other-endpoint"
		}
		var err error
		p.AttestationResult, err = json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		if err := st.UpsertProvider(ctx, p); err != nil {
			t.Fatal(err)
		}
		legacyMDMProof(t, st, p)
		return p
	}
	var historical []store.ProviderRecord
	for i := 0; i < 124; i++ {
		historical = append(historical, seed(fmt.Sprintf("historical-%03d", i), true))
	}
	unbound := seed("unbound", false)
	invalid := seed("invalid", true)
	invalid.AttestationResult = json.RawMessage(`{"Valid":false}`)
	if err := st.UpsertProvider(ctx, invalid); err != nil {
		t.Fatal(err)
	}
	policy := legacymdm.New(store.NewCached(st, store.CacheConfig{}))
	cfg := attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}
	if err := policy.Initialize(ctx, cfg); err != nil {
		t.Fatal(err)
	}
	for _, p := range historical {
		if !policy.IdentityAllowed(p.AccountID, p.SEPublicKey, p.SerialNumber) {
			t.Fatalf("historical machine excluded: %s", p.ID)
		}
	}
	if policy.IdentityAllowed(unbound.AccountID, unbound.SEPublicKey, unbound.SerialNumber) {
		t.Fatal("backfill accepted endpoint-unbound ownership")
	}
	if policy.IdentityAllowed(invalid.AccountID, invalid.SEPublicKey, invalid.SerialNumber) {
		t.Fatal("backfill accepted invalid historical attestation")
	}
	late := seed("late", true)
	restarted := legacymdm.New(store.NewCached(st, store.CacheConfig{}))
	if err := restarted.Initialize(ctx, cfg); err != nil {
		t.Fatal(err)
	}
	if n, err := st.BackfillMachineInventory(ctx, 100); err != nil || n != 0 {
		t.Fatalf("startup left historical rows unprocessed: n=%d err=%v", n, err)
	}
	if restarted.IdentityAllowed(late.AccountID, late.SEPublicKey, late.SerialNumber) {
		t.Fatal("later backfilled alias expanded the frozen cohort")
	}
}
