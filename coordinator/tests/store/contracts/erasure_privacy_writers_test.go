package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// These operations were admitted while the user was live. Their durable writes
// can arrive after the scrub; canceling erasure must leave them usable.
func TestErasureFencesDelayedPersonalWrites(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, cancel := range []bool{false, true} {
				name := "scrubbed"
				if cancel {
					name = "canceled"
				}
				t.Run(name, func(t *testing.T) {
					ctx := context.Background()
					a := erasurefixture.SeedAccount(t, s)
					now := time.Now().UTC()
					archive, ok := store.As[store.AppAttestArchiveStore](s)
					if !ok {
						t.Fatal("archive unavailable")
					}
					// Evidence can precede both asynchronous registry persistence and session open.
					session := erasurefixture.UniqueID("early-session")
					evidence := store.AppAttestEvidence{AccountID: a.AccountID, ID: erasurefixture.UniqueID("proof"), SessionID: session, KeyID: erasurefixture.UniqueID("appkey"), ReceivedAt: now, Context: json.RawMessage(`{"boot_time":"personal"}`), Proof: []byte("personal proof")}
					if err := archive.BeginAppAttestEvidence(ctx, evidence); err != nil {
						t.Fatal(err)
					}
					if err := s.OpenProviderSession(ctx, a.ProviderID, "", ""); err != nil {
						t.Fatal(err)
					}
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					if cancel {
						if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin", now); err != nil {
							t.Fatal(err)
						}
					} else {
						if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
							t.Fatal(err)
						}
					}
					check := func(op string, err error) {
						t.Helper()
						if cancel && err != nil {
							t.Fatalf("%s after cancel: %v", op, err)
						}
						if !cancel && !errors.Is(err, store.ErrErasureConflict) {
							t.Fatalf("%s after scrub: %v", op, err)
						}
					}
					_, err := archive.CompleteAppAttestEvidence(ctx, evidence.ID, store.AppAttestDecision{Outcome: "rejected", Receipt: &store.AppAttestReceipt{ID: erasurefixture.UniqueID("receipt"), KeyID: evidence.KeyID, EvidenceID: evidence.ID, ReceivedAt: now, Outcome: "rejected", Context: json.RawMessage(`{}`), Details: json.RawMessage(`{}`), Body: []byte("personal receipt")}})
					check("evidence completion", err)
					evidence.ID = erasurefixture.UniqueID("late-proof")
					check("evidence begin", archive.BeginAppAttestEvidence(ctx, evidence))
					// Both known blank sessions and wholly delayed opens must enforce ownership.
					check("session touch", s.TouchProviderSession(ctx, a.ProviderID, "personal serial", a.AccountID, "provider-key", now))
					check("delayed open", s.OpenProviderSession(ctx, erasurefixture.UniqueID("late-session"), "personal serial", a.AccountID))
					_, err = s.StoreLogReport(a.AccountID, []byte("personal logs"))
					check("log report", err)
					check("queued code proof", s.UpsertCodeAttestation(ctx, store.CodeAttestation{AccountID: a.AccountID, SEPubKey: a.SEKey, AttestedAt: now, APNsToken: "personal-token"}))
				})
			}
		})
	}
}

func TestErasurePreservesSharedDeviceProofButNotAccountEvidence(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a, b := erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			p, err := s.GetProviderRecord(ctx, b.ProviderID)
			if err != nil {
				t.Fatal(err)
			}
			p.SEPublicKey = a.SEKey
			if err = s.UpsertProvider(ctx, *p); err != nil {
				t.Fatal(err)
			}
			archive, _ := store.As[store.AppAttestArchiveStore](s)
			key := erasurefixture.UniqueID("shared-app-key")
			ids := map[string]string{}
			for _, owner := range []erasurefixture.Account{a, b} {
				id := erasurefixture.UniqueID("shared-evidence")
				ids[owner.AccountID] = id
				if err := archive.BeginAppAttestEvidence(ctx, store.AppAttestEvidence{AccountID: owner.AccountID, ID: id, SessionID: owner.ProviderID, KeyID: key, ReceivedAt: now, Context: json.RawMessage(`{}`)}); err != nil {
					t.Fatal(err)
				}
			}
			req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
			if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
				t.Fatal(err)
			}
			// Captured A's device proof remains useful to live B, while A's transcript does not.
			if err := s.UpsertCodeAttestation(ctx, store.CodeAttestation{AccountID: a.AccountID, SEPubKey: a.SEKey, AttestedAt: now, APNsToken: "shared-device-token"}); err != nil {
				t.Fatal(err)
			}
			if _, err := archive.CompleteAppAttestEvidence(ctx, ids[a.AccountID], store.AppAttestDecision{Outcome: "rejected"}); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("erased evidence completed: %v", err)
			}
			if _, err := archive.CompleteAppAttestEvidence(ctx, ids[b.AccountID], store.AppAttestDecision{Outcome: "rejected"}); err != nil {
				t.Fatal(err)
			}
			req = erasurefixture.PlanAndConfirm(t, s, b, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now.Add(2*time.Hour)); err != nil {
				t.Fatal(err)
			}
			if err := s.UpsertCodeAttestation(ctx, store.CodeAttestation{AccountID: a.AccountID, SEPubKey: a.SEKey, AttestedAt: now, APNsToken: "shared-device-token"}); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("last erased owner restored proof: %v", err)
			}
		})
	}
}

func TestErasureRevalidatesCapturedCheckoutReferrer(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			for _, cancel := range []bool{false, true} {
				name := "scrubbed"
				if cancel {
					name = "canceled"
				}
				t.Run(name, func(t *testing.T) {
					a, b, c := erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s)
					code := erasurefixture.UniqueID("PERSONAL-CODE")
					if err := s.CreateReferrer(a.AccountID, code); err != nil {
						t.Fatal(err)
					}
					captured, err := s.GetReferrerByCode(code)
					if err != nil {
						t.Fatal(err)
					}
					now := time.Now().UTC()
					req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
					if cancel {
						if _, err := s.CancelAccountErasure(context.Background(), a.AccountID, "admin", now); err != nil {
							t.Fatal(err)
						}
					} else {
						if _, err := s.ScrubAccount(context.Background(), req.ID, now.Add(2*time.Hour)); err != nil {
							t.Fatal(err)
						}
						if err := s.CreateReferrer(c.AccountID, code); err != nil {
							t.Fatal(err)
						}
					}
					session := &store.BillingSession{ID: erasurefixture.UniqueID("checkout"), AccountID: b.AccountID, PaymentMethod: "stripe", ExternalID: erasurefixture.UniqueID("cs_live"), Status: "pending", ReferralCode: code, ReferrerAccountID: captured.AccountID}
					if err := s.CreateBillingSession(session); err != nil {
						t.Fatal(err)
					}
					got, err := s.GetBillingSession(session.ID)
					if err != nil {
						t.Fatal(err)
					}
					want := ""
					if cancel {
						want = code
					}
					if got.ReferralCode != want || got.Status != "pending" || got.ExternalID != session.ExternalID {
						t.Fatalf("live payer session = %+v", got)
					}
				})
			}
		})
	}
}
