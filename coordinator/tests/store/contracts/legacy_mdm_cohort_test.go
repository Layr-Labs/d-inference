package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
)

func legacyMDMFixture(t *testing.T, s store.Store, id string, authenticated bool) store.ProviderRecord {
	t.Helper()
	ctx := context.Background()
	if err := s.CreateUser(&store.User{AccountID: id, PrivyUserID: id}); err != nil {
		t.Fatal(err)
	}
	p := store.ProviderRecord{ID: id, AccountID: id, SEPublicKey: "se-" + id, SerialNumber: "serial-" + id, RegisteredAt: time.Now().Add(-time.Hour), LastSeen: time.Now(), Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`)}
	if err := s.UpsertProvider(ctx, p); err != nil {
		t.Fatal(err)
	}
	if authenticated {
		inventory, ok := store.As[store.MachineInventoryStore](s)
		if !ok {
			t.Fatal("missing inventory store")
		}
		if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: id, AccountID: id, SEKey: p.SEPublicKey, At: time.Now().Add(-time.Minute)}); err != nil {
			t.Fatal(err)
		}
	}
	return p
}

func legacyMDMProof(t *testing.T, s store.Store, p store.ProviderRecord) {
	t.Helper()
	_, err := s.UpsertProviderTrustReuse(context.Background(), store.ProviderTrustReuse{SEPubKey: p.SEPublicKey, Serial: p.SerialNumber, TrustLevel: "hardware", MDAUDID: "udid", SIPEnabled: true, SecureBootFull: true, HardwareProofVerifiedAt: time.Now().Add(-time.Minute)}, 0)
	if err != nil {
		t.Fatal(err)
	}
}

func TestLegacyMDMCohortEvidence(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			eligible := legacyMDMFixture(t, s, "eligible", true)
			legacyMDMProof(t, s, eligible)
			// Historical successful MDM still counts after a hard revocation.
			revoked := legacyMDMFixture(t, s, "revoked", true)
			legacyMDMProof(t, s, revoked)
			if _, err := s.RevokeProviderTrustReuse(ctx, revoked.SEPublicKey, "revoke"); err != nil {
				t.Fatal(err)
			}
			legacyMDMFixture(t, s, "no-proof", true)
			unbound := legacyMDMFixture(t, s, "unbound-owner", false)
			legacyMDMProof(t, s, unbound)
			tombstone := legacyMDMFixture(t, s, "tombstone", true)
			if _, err := s.RevokeProviderTrustReuse(ctx, tombstone.SEPublicKey, "only-revoke"); err != nil {
				t.Fatal(err)
			}
			copied := legacyMDMFixture(t, s, "copied", true)
			copied.SerialNumber = eligible.SerialNumber
			if err := s.UpsertProvider(ctx, copied); err != nil {
				t.Fatal(err)
			}
			for _, missing := range []string{"serial", "udid", "sip", "boot", "future", "zero-proof-time"} {
				p := legacyMDMFixture(t, s, missing, true)
				r := store.ProviderTrustReuse{SEPubKey: p.SEPublicKey, Serial: p.SerialNumber, MDAUDID: "udid", SIPEnabled: true, SecureBootFull: true, HardwareProofVerifiedAt: time.Now().Add(-time.Minute)}
				switch missing {
				case "serial":
					r.Serial = "different"
				case "udid":
					r.MDAUDID = ""
				case "sip":
					r.SIPEnabled = false
				case "boot":
					r.SecureBootFull = false
				case "future":
					r.HardwareProofVerifiedAt = time.Now().Add(time.Hour)
				case "zero-proof-time":
					r.HardwareProofVerifiedAt = time.Time{}
				}
				if _, err := s.UpsertProviderTrustReuse(ctx, r, 0); err != nil {
					t.Fatal(err)
				}
			}
			for _, kind := range []string{"hashless", "bad-attestation", "wrong-key", "wrong-serial", "not-attested", "self-signed", "hashless-unbound", "noncanonical-attestation"} {
				p := legacyMDMFixture(t, s, kind, kind != "hashless-unbound")
				p.TrustLevel, p.Attested = "hardware", true
				a := map[string]any{"Valid": true, "SecureEnclaveAvailable": true, "SIPEnabled": true, "SecureBootEnabled": true, "PublicKey": p.SEPublicKey, "SerialNumber": p.SerialNumber}
				switch kind {
				case "bad-attestation":
					a["SIPEnabled"] = false
				case "wrong-key":
					a["PublicKey"] = "other"
				case "wrong-serial":
					a["SerialNumber"] = "other"
				case "not-attested":
					p.Attested = false
				case "self-signed":
					p.TrustLevel = "self_signed"
				case "noncanonical-attestation":
					delete(a, "Valid")
					a["valid"] = true
				}
				p.AttestationResult, _ = json.Marshal(a)
				if err := s.UpsertProvider(ctx, p); err != nil {
					t.Fatal(err)
				}
			}
			accountMismatch := legacyMDMFixture(t, s, "account-mismatch", false)
			legacyMDMProof(t, s, accountMismatch)
			inventory, _ := store.As[store.MachineInventoryStore](s)
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "other-owner", AccountID: "other-owner", SEKey: accountMismatch.SEPublicKey, At: time.Now().Add(-time.Minute)}); err != nil {
				t.Fatal(err)
			}
			freeze, ok := store.As[store.LegacyMDMCohortStore](store.NewCached(s, store.CacheConfig{}))
			if !ok {
				t.Fatal("optional interface not discoverable through cache")
			}
			got, err := freeze.FreezeLegacyMDMCohort(ctx)
			want := []store.LegacyMDMMachine{
				{AccountID: "eligible", SEPublicKey: eligible.SEPublicKey, SerialNumber: eligible.SerialNumber},
				{AccountID: "hashless", SEPublicKey: "se-hashless", SerialNumber: "serial-hashless"},
				{AccountID: "revoked", SEPublicKey: revoked.SEPublicKey, SerialNumber: revoked.SerialNumber},
			}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("freeze = %+v, %v; want %+v", got, err, want)
			}
			// Later proof, new account/device, linking, and transfer cannot widen it.
			late := legacyMDMFixture(t, s, "late", true)
			legacyMDMProof(t, s, late)
			legacyMDMProof(t, s, store.ProviderRecord{SEPublicKey: "se-no-proof", SerialNumber: "serial-no-proof"})
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "linked", AccountID: unbound.AccountID, SEKey: unbound.SEPublicKey, At: time.Now()}); err != nil {
				t.Fatal(err)
			}
			eligible.AccountID = late.AccountID
			eligible.TrustLevel = "none"
			eligible.AttestationResult = json.RawMessage(`{}`)
			if err := s.UpsertProvider(ctx, eligible); err != nil {
				t.Fatal(err)
			}
			revocation, err := s.RevokeProviderTrustReuse(ctx, eligible.SEPublicKey, "later")
			if err != nil {
				t.Fatal(err)
			}
			rewritten, err := s.RecoverProviderTrustReuse(ctx, store.ProviderTrustReuse{SEPubKey: eligible.SEPublicKey, Serial: "replacement-serial", HardwareProofVerifiedAt: time.Now()}, revocation.RevocationGeneration)
			if err != nil || !rewritten.Applied {
				t.Fatalf("overwrite proof = %+v, %v", rewritten, err)
			}
			got[0].AccountID = "mutated-return"
			var wg sync.WaitGroup
			for i := 0; i < 4; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					rows, err := freeze.FreezeLegacyMDMCohort(ctx)
					if err != nil || !reflect.DeepEqual(rows, want) {
						t.Errorf("repeat = %+v, %v", rows, err)
					}
				}()
			}
			wg.Wait()
			if _, ok := s.(*postgres.PostgresStore); ok {
				reopened, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: os.Getenv("DATABASE_URL")})
				if err != nil {
					t.Fatal(err)
				}
				defer reopened.Close()
				rows, err := reopened.FreezeLegacyMDMCohort(ctx)
				if err != nil || !reflect.DeepEqual(rows, want) {
					t.Fatalf("restart = %+v, %v", rows, err)
				}
			}
		})
	}
}

func TestLegacyMDMCohortCutoff(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			future := time.Now().Add(time.Hour)
			creationTime := future
			// The memory backend supports an injected creation clock; PostgreSQL
			// uses its database clock, so update the isolated fixture via SQL.
			if _, ok := s.(*memory.MemoryStore); ok {
				s = memory.NewMemory(store.Config{Now: func() time.Time { return creationTime }})
			}
			user := legacyMDMFixture(t, s, "future-user", true)
			legacyMDMProof(t, s, user)
			creationTime = time.Now().Add(-time.Minute)
			var pool *pgxpool.Pool
			if _, ok := s.(*postgres.PostgresStore); ok {
				var err error
				pool, err = pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
				if err != nil {
					t.Fatal(err)
				}
				defer pool.Close()
				if _, err := pool.Exec(ctx, `UPDATE users SET created_at=$1 WHERE account_id=$2`, future, user.AccountID); err != nil {
					t.Fatal(err)
				}
			}
			provider := legacyMDMFixture(t, s, "future-provider", true)
			legacyMDMProof(t, s, provider)
			provider.RegisteredAt = future
			if pool != nil {
				// PostgreSQL preserves registration time on provider upsert.
				if _, err := pool.Exec(ctx, `UPDATE providers SET registered_at=$1 WHERE id=$2`, future, provider.ID); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := s.UpsertProvider(ctx, provider); err != nil {
					t.Fatal(err)
				}
			}
			freeze, _ := store.As[store.LegacyMDMCohortStore](s)
			rows, err := freeze.FreezeLegacyMDMCohort(ctx)
			if err != nil || len(rows) != 0 {
				t.Fatalf("future evidence freeze = %+v, %v", rows, err)
			}
		})
	}
}

func TestLegacyMDMCohortConflictingSerials(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			for _, id := range []string{"conflicting-hardware", "unproved-conflict"} {
				p := legacyMDMFixture(t, s, id, true)
				p.TrustLevel, p.Attested = "hardware", true
				for i := 0; i < 2; i++ {
					if i == 1 {
						p.ID += "-other"
						p.SerialNumber += "-other"
						if id == "unproved-conflict" {
							p.TrustLevel = "self_signed"
						}
					}
					p.AttestationResult, _ = json.Marshal(map[string]any{"Valid": true, "SecureEnclaveAvailable": true, "SIPEnabled": true, "SecureBootEnabled": true, "PublicKey": p.SEPublicKey, "SerialNumber": p.SerialNumber})
					if err := s.UpsertProvider(ctx, p); err != nil {
						t.Fatal(err)
					}
				}
			}
			freeze, _ := store.As[store.LegacyMDMCohortStore](s)
			got, err := freeze.FreezeLegacyMDMCohort(ctx)
			want := []store.LegacyMDMMachine{{AccountID: "unproved-conflict", SEPublicKey: "se-unproved-conflict", SerialNumber: "serial-unproved-conflict"}}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("serial conflict freeze = %+v, %v; want %+v", got, err, want)
			}
		})
	}
}

func TestLegacyMDMCohortMultipleAuthenticatedScopes(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			first := legacyMDMFixture(t, s, "first", true)
			legacyMDMProof(t, s, first)
			second := legacyMDMFixture(t, s, "second", false)
			second.SEPublicKey, second.SerialNumber = first.SEPublicKey, first.SerialNumber
			if err := s.UpsertProvider(ctx, second); err != nil {
				t.Fatal(err)
			}
			inventory, _ := store.As[store.MachineInventoryStore](s)
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: second.ID, AccountID: second.AccountID, SEKey: second.SEPublicKey, At: time.Now().Add(-time.Minute)}); err != nil {
				t.Fatal(err)
			}
			freeze, _ := store.As[store.LegacyMDMCohortStore](s)
			rows, err := freeze.FreezeLegacyMDMCohort(ctx)
			want := []store.LegacyMDMMachine{
				{AccountID: first.AccountID, SEPublicKey: first.SEPublicKey, SerialNumber: first.SerialNumber},
				{AccountID: second.AccountID, SEPublicKey: second.SEPublicKey, SerialNumber: second.SerialNumber},
			}
			if err != nil || !reflect.DeepEqual(rows, want) {
				t.Fatalf("multiple authenticated scopes = %+v, %v; want %+v", rows, err, want)
			}
		})
	}
}

func TestLegacyMDMCohortCancelledFreeze(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			freeze, _ := store.As[store.LegacyMDMCohortStore](s)
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if _, err := freeze.FreezeLegacyMDMCohort(ctx); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled freeze = %v", err)
			}
			p := legacyMDMFixture(t, s, "retry", true)
			legacyMDMProof(t, s, p)
			rows, err := freeze.FreezeLegacyMDMCohort(context.Background())
			want := []store.LegacyMDMMachine{{AccountID: p.AccountID, SEPublicKey: p.SEPublicKey, SerialNumber: p.SerialNumber}}
			if err != nil || !reflect.DeepEqual(rows, want) {
				t.Fatalf("retry freeze = %+v, %v; want %+v", rows, err, want)
			}
		})
	}
}

func TestLegacyMDMCohortEmptyFreeze(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			freeze, _ := store.As[store.LegacyMDMCohortStore](s)
			rows, err := freeze.FreezeLegacyMDMCohort(context.Background())
			if err != nil || len(rows) != 0 {
				t.Fatalf("empty freeze: %+v, %v", rows, err)
			}
			p := legacyMDMFixture(t, s, "after-empty", true)
			legacyMDMProof(t, s, p)
			rows, err = freeze.FreezeLegacyMDMCohort(context.Background())
			if err != nil || len(rows) != 0 {
				t.Fatalf("widened empty freeze: %+v, %v", rows, err)
			}
			if _, ok := s.(*postgres.PostgresStore); ok {
				reopened, err := postgres.NewPostgres(context.Background(), store.Config{DatabaseURL: os.Getenv("DATABASE_URL")})
				if err != nil {
					t.Fatal(err)
				}
				defer reopened.Close()
				rows, err = reopened.FreezeLegacyMDMCohort(context.Background())
				if err != nil || len(rows) != 0 {
					t.Fatalf("restart widened empty freeze: %+v, %v", rows, err)
				}
			}
		})
	}
}
