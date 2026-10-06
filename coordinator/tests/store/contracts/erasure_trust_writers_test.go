package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureFencesDelayedTrustWriters(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, mode := range []string{"scrubbed", "canceled", "shared-live-owner"} {
				t.Run(mode, func(t *testing.T) {
					ctx := context.Background()
					a := erasurefixture.SeedAccount(t, s)
					now := time.Now().UTC()
					rec := store.ProviderTrustReuse{SEPubKey: a.SEKey, Serial: "private-serial", MDAUDID: "private-udid", TrustLevel: "hardware", HardwareProofVerifiedAt: now, LastVerifiedBinaryHash: "abc"}
					first, err := s.UpsertProviderTrustReuse(ctx, rec, 0)
					if err != nil || !first.Applied {
						t.Fatalf("seed trust: %+v, %v", first, err)
					}
					if mode == "shared-live-owner" {
						b := erasurefixture.SeedAccount(t, s)
						p, err := s.GetProviderRecord(ctx, b.ProviderID)
						if err != nil {
							t.Fatal(err)
						}
						p.SEPublicKey = a.SEKey
						if err := s.UpsertProvider(ctx, *p); err != nil {
							t.Fatal(err)
						}
					}
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					if mode == "canceled" {
						if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now); err != nil {
							t.Fatal(err)
						}
					} else if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
						t.Fatal(err)
					}
					for _, write := range []struct {
						name string
						run  func(context.Context, store.ProviderTrustReuse, uint64) (store.ProviderTrustReuseWriteResult, error)
					}{{"upsert", s.UpsertProviderTrustReuse}, {"recover", s.RecoverProviderTrustReuse}} {
						got, err := write.run(ctx, rec, first.RevocationGeneration)
						if mode == "scrubbed" {
							if !errors.Is(err, store.ErrErasureConflict) || got.Applied {
								t.Fatalf("%s restored erased trust: %+v, %v", write.name, got, err)
							}
						} else if err != nil || !got.Applied {
							t.Fatalf("%s refused live identity: %+v, %v", write.name, got, err)
						}
					}
					_, err = s.UpsertVerificationJob(ctx, store.VerificationJob{SEPubKey: a.SEKey, Serial: rec.Serial, UDID: rec.MDAUDID, Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending, UpdatedAt: now})
					if mode == "scrubbed" {
						if !errors.Is(err, store.ErrErasureConflict) {
							t.Fatalf("verification job restored: %v", err)
						}
						rows, err := s.ListProviderTrustReuse(ctx)
						if err != nil {
							t.Fatal(err)
						}
						for _, row := range rows {
							if row.SEPubKey == a.SEKey && (row.Serial != "" || row.MDAUDID != "") {
								t.Fatalf("personal trust data retained: %+v", row)
							}
						}
						if row, err := s.GetVerificationJob(ctx, a.SEKey, store.VerificationTaskSecurityInfo); err != nil || row != nil {
							t.Fatalf("verification job retained: %+v %v", row, err)
						}
					} else if err != nil {
						t.Fatalf("verification job refused live identity: %v", err)
					}
				})
			}
		})
	}
}

func TestErasureFencesDelayedInventoryAndReferralRegistration(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, mode := range []string{"scrubbed", "pending", "canceled"} {
				t.Run(mode, func(t *testing.T) {
					ctx := context.Background()
					a := erasurefixture.SeedAccount(t, s)
					now := time.Now().UTC()
					inv, ok := store.As[store.MachineInventoryStore](s)
					if !ok {
						t.Fatal("missing inventory store")
					}
					o := store.MachineObservation{SessionID: a.ProviderID, AccountID: a.AccountID, SEKey: a.SEKey, VerifiedSerial: "personal-serial", At: now, Source: "live_registration"}
					if _, err := inv.ObserveMachine(ctx, o); err != nil {
						t.Fatal(err)
					}
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					switch mode {
					case "canceled":
						if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now); err != nil {
							t.Fatal(err)
						}
					case "scrubbed":
						if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
							t.Fatal(err)
						}
					}
					o.At = now.Add(3 * time.Hour)
					o.Disconnected = true
					_, err := inv.ObserveMachine(ctx, o)
					if mode == "canceled" {
						if err != nil {
							t.Fatal(err)
						}
					} else if !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("late inventory: %v", err)
					}
					code := erasurefixture.UniqueID("personal-family-name")
					err = s.CreateReferrer(a.AccountID, code)
					if mode == "canceled" {
						if err != nil {
							t.Fatal(err)
						}
					} else if !errors.Is(err, store.ErrErasureConflict) {
						t.Fatalf("late referrer: %v", err)
					}
				})
			}
		})
	}
}
