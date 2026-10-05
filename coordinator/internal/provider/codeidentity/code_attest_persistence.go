package codeidentity

import (
	"context"
	"time"

	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller,

) SeedCodeAttestCache(ctx context.Context) {
	if s == nil || s.codeAttestThrottle == nil || s.store == nil {
		return
	}
	// Wire the write-through path so future successful round-trips are persisted.
	s.codeAttestThrottle.Store = s.store

	rows, err := s.store.ListCodeAttestations(ctx)
	if err != nil {
		s.logger.Warn("code-attest: failed to seed reuse cache from store", "error", err)
	} else if n := s.codeAttestThrottle.Seed(rows); n > 0 {
		s.logger.Info("code-attest: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	if st, ok := store.As[codeidentity.PushBudgetStore](s.store); ok {
		budgets, err := st.ListCodeAttestPushBudgets(ctx)
		if err != nil {
			s.logger.Warn("code-attest: failed to seed durable push budgets", "error", err)
		} else {
			s.codeAttestThrottle.SeedPushBudgets(budgets)
		}
	}
}

// recordResumeChallenge stores a one-time, connection-bound X25519 PoP nonce
// with the exact resume deadline. APNs challenges intentionally use the longer
// challengeValidity window; live-connection resume proofs do not.
func (s *Controller,

) persistCodeAttestation(seKey, version, token, nodeKey, binaryHash string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.Store
	if st == nil {
		return
	}
	proof, ok := s.codeAttestThrottle.ProofForIdentity(seKey, version, token, nodeKey, binaryHash)
	if !ok {
		return
	}
	proof.ContinuousCoverageUntil = nil // only a verified observation can advance coverage
	saferun.Go(s.logger, "persistCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.UpsertCodeAttestation(ctx, proof); err != nil {
			s.logger.Warn("code-attest: failed to persist reuse record", "error", err)
		}
	})
}

// invalidatePersistedCodeAttestation deletes a device's PERSISTED reuse row off
// the read loop. Called alongside the in-memory invalidateReuse when a provider's
// APNs token CHANGES, so a coordinator restart before the forced re-challenge
// completes cannot reseed and reuse the pre-rotation proof (Codex #6). No-op when
// no store is wired. The persisted row is only a re-push optimization — never a
// grant of CodeAttested — so deleting it can never weaken fail-closed identity.
func (s *Controller,

) invalidatePersistedCodeAttestation(seKey string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.Store
	if st == nil {
		return
	}
	saferun.Go(s.logger, "invalidatePersistedCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.DeleteCodeAttestation(ctx, seKey); err != nil {
			s.logger.Warn("code-attest: failed to delete persisted reuse record on token change", "error", err)
		}
	})
}
