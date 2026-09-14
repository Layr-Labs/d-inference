package codeidentity

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// persistCodeAttestation best-effort writes a successful code-identity round-trip
// to the store so it survives a coordinator restart/deploy. It mirrors
// the in-memory recordAttested and is called from the same event
// (HandleResponse). Behind the store seam (no-op until
// Seed wires a store): prod runs the Postgres store, so this makes
// reuse durable across blue-green deploys (avoiding a fleet-wide re-push storm).
// Runs off the read loop (saferun.Go) so the DB write never stalls WebSocket
// reads. SECURITY: writes only AFTER the full nonce-match + SE-signature
// verification — never from an unverified heartbeat token.
func (s *Manager) persistCodeAttestation(seKey, version, token, nodeKey, binaryHash string) {
	if s == nil || s.state == nil || seKey == "" {
		return
	}
	st := s.state.store
	if st == nil {
		return
	}
	t := s.state
	t.mu.Lock()
	record, ok := t.attested[seKey]
	t.mu.Unlock()
	if !ok || record.version != version || record.token != token || record.nodeKey != nodeKey || record.binaryHash != binaryHash {
		return
	}
	proof := record.persisted(seKey)
	proof.ContinuousCoverageUntil = nil // only a verified observation can advance coverage
	saferun.Go(s.deps.Logger, "persistCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.UpsertCodeAttestation(ctx, proof); err != nil {
			s.deps.Logger.Warn("code-attest: failed to persist reuse record", "error", err)
		}
	})
}

// invalidatePersistedCodeAttestation deletes a device's PERSISTED reuse row off
// the read loop. Called alongside the in-memory invalidateReuse when a provider's
// APNs token CHANGES, so a coordinator restart before the forced re-challenge
// completes cannot reseed and reuse the pre-rotation proof. No-op when
// no store is wired. The persisted row is only a re-push optimization — never a
// grant of CodeAttested — so deleting it can never weaken fail-closed identity.
func (s *Manager) invalidatePersistedCodeAttestation(seKey string) {
	if s == nil || s.state == nil || seKey == "" {
		return
	}
	st := s.state.store
	if st == nil {
		return
	}
	saferun.Go(s.deps.Logger, "invalidatePersistedCodeAttest", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.DeleteCodeAttestation(ctx, seKey); err != nil {
			s.deps.Logger.Warn("code-attest: failed to delete persisted reuse record on token change", "error", err)
		}
	})
}
