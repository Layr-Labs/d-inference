package trust

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) SeedCodeAttestCache(ctx context.Context) {
	if s == nil || s.codeAttestThrottle == nil || s.store == nil {
		return
	}
	// Wire the write-through path so future successful round-trips are persisted.
	s.codeAttestThrottle.store = s.store

	rows, err := s.store.ListCodeAttestations(ctx)
	if err != nil {
		s.logger.Warn("code-attest: failed to seed reuse cache from store", "error", err)
	} else if n := s.codeAttestThrottle.seed(rows); n > 0 {
		s.logger.Info("code-attest: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	if st, ok := store.As[codeAttestPushBudgetStore](s.store); ok {
		budgets, err := st.ListCodeAttestPushBudgets(ctx)
		if err != nil {
			s.logger.Warn("code-attest: failed to seed durable push budgets", "error", err)
		} else {
			th := s.codeAttestThrottle
			th.mu.Lock()
			for _, budget := range budgets {
				if budget.SEPubKey == "" {
					continue
				}
				if budget.TokenHash == "" {
					// Sentinel row: the per-SE-key novel-token admission floor
					// (also the shape of legacy pre-composite rows, whose
					// per-SE budget means exactly this). Codex P1. Its
					// LastClearAt seeds the rotation-clear cooldown, so a
					// restart cannot re-grant a floor clear the previous
					// instance already spent (Codex 06:36Z P1) — even when the
					// floor itself has already elapsed.
					if budget.LastClearAt.After(th.lastBudgetClear[budget.SEPubKey]) {
						th.lastBudgetClear[budget.SEPubKey] = budget.LastClearAt
					}
					if budget.NextPushAt.After(th.now()) &&
						budget.NextPushAt.After(th.novelPushFloor[budget.SEPubKey]) {
						th.novelPushFloor[budget.SEPubKey] = budget.NextPushAt
					}
					continue
				}
				if !budget.NextPushAt.After(th.now()) {
					continue
				}
				key := codeAttestPushBudgetKey(
					budget.SEPubKey, budget.TokenHash,
				)
				th.durableNextPush[key] = budget.NextPushAt
				th.noteBudgetTokenReservationHeld(
					budget.SEPubKey, budget.TokenHash,
				)
			}
			th.mu.Unlock()
		}
	}
}

// recordResumeChallenge stores a one-time, connection-bound X25519 PoP nonce
// with the exact resume deadline. APNs challenges intentionally use the longer
// challengeValidity window; live-connection resume proofs do not.
func (s *Owner) persistCodeAttestation(seKey, version, token, nodeKey, binaryHash string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.store
	if st == nil {
		return
	}
	t := s.codeAttestThrottle
	t.mu.Lock()
	record, ok := t.attested[seKey]
	t.mu.Unlock()
	if !ok || record.version != version || record.token != token || record.nodeKey != nodeKey || record.binaryHash != binaryHash {
		return
	}
	proof := record.persisted(seKey)
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
func (s *Owner) invalidatePersistedCodeAttestation(seKey string) {
	if s == nil || s.codeAttestThrottle == nil || seKey == "" {
		return
	}
	st := s.codeAttestThrottle.store
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
