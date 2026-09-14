package registry

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (r *Registry) SetStore(st store.Store) {
	r.store = st
}

// PersistProvider unconditionally persists provider state to the store.
// Use for critical state changes (attestation, trust level, disconnect).
func (r *Registry) PersistProvider(p *Provider) {
	r.persistProviderNow(p)
}

// PersistProviderThrottled persists provider state at most once per 30 seconds.
// Use for high-frequency updates (heartbeats) that would otherwise saturate the
// DB connection pool. Skipped writes are not lost — the next unthrottled persist
// or the next throttle window will capture the current state.
func (r *Registry) PersistProviderThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastPersisted = time.Now()
	p.mu.Unlock()
	r.persistProviderNow(p)
}

// persistProviderNow saves a provider's current state to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistProviderNow(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistProvider", func() {
		p.persistMu.Lock()
		defer p.persistMu.Unlock()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		hardwareJSON, _ := json.Marshal(p.Hardware)
		modelsJSON, _ := json.Marshal(p.Models)
		var attestJSON json.RawMessage
		if p.AttestationResult != nil {
			attestJSON, _ = json.Marshal(p.AttestationResult)
		}
		seKey := ""
		serial := ""
		if p.AttestationResult != nil && !p.stateRestorePending {
			seKey = p.AttestationResult.PublicKey
			serial = p.AttestationResult.SerialNumber
		}
		providerKey := p.PublicKey // X25519 key — earnings/session identity (base rewards)
		var mdaCertJSON json.RawMessage
		if len(p.MDACertChain) > 0 {
			mdaCertJSON, _ = json.Marshal(p.MDACertChain)
		}
		var lastChallenge *time.Time
		if !p.LastChallengeVerified.IsZero() {
			t := p.LastChallengeVerified
			lastChallenge = &t
		}

		var locationCopy *store.ProviderLocation
		if p.Location != nil {
			lc := *p.Location
			locationCopy = &lc
		}
		statsJSON, _ := json.Marshal(p.Stats)
		lastSessionStatsJSON, _ := json.Marshal(p.lastSessionStats)

		rec := store.ProviderRecord{
			ID:                         p.ID,
			Hardware:                   hardwareJSON,
			Models:                     modelsJSON,
			Backend:                    p.Backend,
			Location:                   locationCopy,
			TrustLevel:                 string(p.TrustLevel),
			Attested:                   p.Attested,
			AttestationResult:          attestJSON,
			SEPublicKey:                seKey,
			PublicKey:                  p.PublicKey,
			SerialNumber:               serial,
			MDAVerified:                p.MDAVerified,
			MDACertChain:               mdaCertJSON,
			Version:                    p.Version,
			RuntimeVerified:            p.RuntimeVerified,
			PythonHash:                 p.PythonHash,
			RuntimeHash:                p.RuntimeHash,
			LastChallengeVerified:      lastChallenge,
			FailedChallenges:           p.FailedChallenges,
			AccountID:                  p.AccountID,
			LifetimeRequestsServed:     p.Stats.RequestsServed,
			LifetimeTokensGenerated:    p.Stats.TokensGenerated,
			LastSessionRequestsServed:  p.lastSessionStats.RequestsServed,
			LastSessionTokensGenerated: p.lastSessionStats.TokensGenerated,
			LifetimeStats:              statsJSON,
			LastSessionStats:           lastSessionStatsJSON,
			RegisteredAt:               time.Now(),
			LastSeen:                   time.Now(),
		}
		completed := !p.stateRestorePending
		rep := providerReputationRecordLocked(p)
		p.mu.Unlock()

		var err error
		if completed {
			err = r.store.UpsertProviderWithReputation(ctx, rec, rep)
		} else {
			err = r.store.UpsertProvider(ctx, rec)
		}
		if err != nil {
			r.logger.Warn("failed to persist provider", "provider_id", p.ID, "error", err)
		}

		// Keep this connection's session row fresh and backfill
		// serial/account/provider_key once attestation/linking has populated them.
		if err := r.store.TouchProviderSession(ctx, rec.ID, rec.SerialNumber, rec.AccountID, providerKey, rec.LastSeen); err != nil {
			r.logger.Warn("failed to touch provider session", "provider_id", rec.ID, "error", err)
		}
	})
}
