package store_test

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Initial cohort qualification needs independent user-only and provider-only
// tombstones. Historical linked evidence is seeded before installing a deleted
// user, so the fixture does not ask current admission to write through deletion.
// Contact pagination and later frozen reads use the real erasure transition.
func createUserWithDeletion(t *testing.T, s store.Store, id string, deletedAt *time.Time) {
	t.Helper()
	if err := s.CreateUser(&store.User{AccountID: id, PrivyUserID: id, Email: id + "@example.test", DeletedAt: deletedAt}); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.(*postgres.PostgresStore); ok && deletedAt != nil {
		softDeleteFixtureExec(t, `UPDATE users SET deleted_at=$1 WHERE account_id=$2`, deletedAt, id)
	}
}

func softDeleteFixtureExec(t *testing.T, query string, args ...any) {
	t.Helper()
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, query, args...); err != nil {
		t.Fatal(err)
	}
}

func TestSmallModelsInterestOmitsDeletedUsersBeforePagination(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			for _, id := range []string{"a-deleted", "b-live", "c-deleted", "d-live", "e-deleted"} {
				var deletedAt *time.Time
				if id != "b-live" && id != "d-live" {
					deletedAt = &now
				}
				createUserWithDeletion(t, s, id, nil)
				if err := s.UpsertSmallModelsInterest(ctx, store.SmallModelsInterest{AccountID: id, MacType: "Mac Mini", Chip: "M4", RAMGB: 16}); err != nil {
					t.Fatal(err)
				}
				if deletedAt != nil {
					erasurefixture.PlanAndConfirm(t, s, erasurefixture.Account{AccountID: id, Email: id + "@example.test"}, now, time.Hour)
				}
			}
			// Deleted contacts at the start and between live rows must not consume
			// the page limit or make a caller stop before all live contacts arrive.
			for _, page := range []struct{ after, want string }{
				{"", "b-live"}, {"b-live", "d-live"}, {"d-live", ""},
			} {
				rows, err := s.ListSmallModelsInterest(ctx, page.after, 1)
				if err != nil {
					t.Fatal(err)
				}
				if page.want == "" {
					if len(rows) != 0 {
						t.Fatalf("last page = %+v; want empty", rows)
					}
				} else if len(rows) != 1 || rows[0].AccountID != page.want || rows[0].Email != page.want+"@example.test" || rows[0].RAMGB != 16 {
					t.Fatalf("page after %q = %+v; want live contact %q", page.after, rows, page.want)
				}
			}
			rows, err := s.ListSmallModelsInterest(ctx, "", 100)
			if err != nil || len(rows) != 2 || rows[0].AccountID != "b-live" || rows[1].AccountID != "d-live" {
				t.Fatalf("all contacts = %+v, %v; want both live contacts", rows, err)
			}
		})
	}
}

func TestLegacyMDMCohortOmitsDeletedInitialEvidence(t *testing.T) {
	for _, proof := range []string{"historical", "hardware"} {
		t.Run(proof, func(t *testing.T) {
			for name, s := range storeBackends(t) {
				t.Run(name, func(t *testing.T) {
					ctx := context.Background()
					now := time.Now().UTC()
					inventory, ok := store.As[store.MachineInventoryStore](s)
					if !ok {
						t.Fatal("missing inventory store")
					}
					var live store.ProviderRecord
					for _, id := range []string{"deleted-user", "deleted-provider", "live"} {
						var deletedAt *time.Time
						if id == "deleted-user" {
							deletedAt = &now
						}
						if deletedAt == nil {
							createUserWithDeletion(t, s, id, nil)
						}
						p := store.ProviderRecord{ID: id, AccountID: id, SEPublicKey: "se-" + id, SerialNumber: "serial-" + id, RegisteredAt: now.Add(-time.Hour), LastSeen: now, Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`)}
						if id == "deleted-provider" {
							p.DeletedAt = &now
						}
						if proof == "hardware" {
							p.TrustLevel, p.Attested = "hardware", true
							p.AttestationResult, _ = json.Marshal(map[string]any{"Valid": true, "SecureEnclaveAvailable": true, "SIPEnabled": true, "SecureBootEnabled": true, "PublicKey": p.SEPublicKey, "SerialNumber": p.SerialNumber})
						} else {
							legacyMDMProof(t, s, p)
						}
						if err := s.UpsertProvider(ctx, p); err != nil {
							t.Fatal(err)
						}
						if _, ok := s.(*postgres.PostgresStore); ok && p.DeletedAt != nil {
							softDeleteFixtureExec(t, `UPDATE providers SET deleted_at=$1 WHERE id=$2`, p.DeletedAt, p.ID)
						}
						if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: id, AccountID: id, SEKey: p.SEPublicKey, At: now.Add(-time.Minute)}); err != nil {
							t.Fatal(err)
						}
						if deletedAt != nil {
							createUserWithDeletion(t, s, id, deletedAt)
						}
						if id == "live" {
							live = p
						}
					}
					freeze, ok := store.As[store.LegacyMDMCohortStore](s)
					if !ok {
						t.Fatal("missing legacy MDM cohort store")
					}
					want := []store.LegacyMDMMachine{{AccountID: live.AccountID, SEPublicKey: live.SEPublicKey, SerialNumber: live.SerialNumber}}
					rows, err := freeze.FreezeLegacyMDMCohort(ctx)
					if err != nil || !reflect.DeepEqual(rows, want) {
						t.Fatalf("initial freeze = %+v, %v; want %+v", rows, err, want)
					}
					// The filter governs initial qualification, not later reads of the
					// durable snapshot. Deleting a provider does not recompute the cohort.
					erasurefixture.PlanAndConfirm(t, s, erasurefixture.Account{AccountID: live.AccountID, Email: live.AccountID + "@example.test"}, now, time.Hour)
					rows, err = freeze.FreezeLegacyMDMCohort(ctx)
					if err != nil || !reflect.DeepEqual(rows, want) {
						t.Fatalf("repeat freeze = %+v, %v; want retained snapshot %+v", rows, err, want)
					}
				})
			}
		})
	}
}
