package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RestoreProviderState restores trust level and reputation from a stored record
// onto a live provider. Called after a provider reconnects and is matched to
// its stored state by serial number or SE key.
func (r *Registry) RestoreProviderState(p *Provider, rec *store.ProviderRecord) error {
	return r.RestoreProviderStateContext(context.Background(), p, rec)
}

// RestoreProviderStateContext shares registration's cancellation/deadline with
// the reputation read, rather than extending a failed lookup with another wait.
func (r *Registry) RestoreProviderStateContext(ctx context.Context, p *Provider, rec *store.ProviderRecord) error {
	if rec == nil {
		return nil
	}
	var repRec *store.ReputationRecord
	if r.store != nil {
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		var err error
		repRec, err = r.store.GetReputation(ctx, rec.ID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return fmt.Errorf("restore reputation: %w", err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Restore trust level, but NEVER above self_signed. Hardware trust must be
	// re-earned via a fresh live challenge + MDM verification on every (re)connection.
	// Resurrecting a stored "hardware" level would route real traffic to a
	// provider that has not yet passed a live challenge, and is the source of
	// the "registry says hardware but the live verdict is self_signed" drift.
	// The challenge-success path (verifyChallengeResponse) re-upgrades to
	// hardware once the live legs pass.
	if r := trustRank(TrustLevel(rec.TrustLevel)); r > trustRank(TrustSelfSigned) {
		p.TrustLevel = TrustSelfSigned
	} else {
		p.TrustLevel = TrustLevel(rec.TrustLevel)
	}
	// Do NOT clobber a fresh live attestation: verification.Verifier.VerifyRegistration runs
	// just before this and may have already set Attested=true (self_signed) from
	// a passing SE attestation. Only fall back to the stored flag when we don't
	// already have a fresh one — otherwise consumers/stats would see
	// X-Provider-Attested:false despite a successful live attestation.
	if !p.Attested {
		p.Attested = rec.Attested
	}
	// Never resurrect the MDA proof from the store. Trust above self_signed was
	// just capped away (see above), so a restored connection is always
	// self_signed or lower — and a hardware proof is only meaningful for the
	// connection that earned it live. Restoring MDAVerified=true here produced the
	// misleading "mda_verified=true while self_signed" drift on
	// /v1/providers/attestation. The flag is re-set by the live MDA leg
	// (verification.Verifier.VerifyMDA) once hardware is re-earned this connection.
	p.MDAVerified = false

	// Stage the durable Apple-signed MDA cert chain (if the store has one) for
	// local re-verification at this connection's hardware-grant. We deliberately
	// do NOT set MDAVerified/MDACertChain here — the proof is surfaced only after
	// verification.Verifier.AttachCachedMDA re-verifies it against Apple's pinned root AND re-binds
	// it to this connection's SE key. This lets a reconnect/restart reuse a
	// still-valid attestation instead of forcing a fresh, Apple-rate-limited
	// (≈1/device/7d) DevicePropertiesAttestation round-trip over the throttled
	// MicroMDM→APNs channel — the root cause of providers showing "Apple Device
	// Attestation incomplete" after a restart.
	p.restoredMDAChain = nil
	if len(rec.MDACertChain) > 0 {
		var chain [][]byte
		if err := json.Unmarshal(rec.MDACertChain, &chain); err == nil && len(chain) > 0 {
			p.restoredMDAChain = chain
		}
	}

	// Restore challenge state, but never move a fresh live verification
	// backwards. Registration attestation sets LastChallengeVerified=now before
	// RestoreProviderState runs; clobbering it with an old persisted timestamp
	// can make a just-reconnected provider fail the freshness gate until the
	// first challenge response lands.
	if rec.LastChallengeVerified != nil && rec.LastChallengeVerified.After(p.LastChallengeVerified) {
		p.LastChallengeVerified = *rec.LastChallengeVerified
	}
	p.FailedChallenges = rec.FailedChallenges

	// Restore location only if the provider doesn't already have a fresh one
	// (attachProviderLocation may have set it from the current request before
	// RestoreProviderState runs).
	if rec.Location != nil && p.Location == nil {
		cp := *rec.Location
		p.Location = &cp
	}

	// Restore account linkage
	if rec.AccountID != "" && p.AccountID == "" {
		p.AccountID = rec.AccountID
	}

	// Restore lifetime counters and the last raw session counters so future
	// heartbeats can merge cleanly after coordinator or provider restarts. The
	// legacy scalar columns keep old DB rows readable; the JSON snapshots carry
	// newer additive heartbeat counters.
	p.Stats = providerRecordStats(rec.LifetimeStats, rec.LifetimeRequestsServed, rec.LifetimeTokensGenerated)
	p.lastSessionStats = providerRecordStats(rec.LastSessionStats, rec.LastSessionRequestsServed, rec.LastSessionTokensGenerated)

	// Missing legacy reputation is allowed; other read failures returned before
	// modifying counters or permitting durable identity publication.
	if repRec != nil {
		p.Reputation.TotalJobs = repRec.TotalJobs
		p.Reputation.SuccessfulJobs = repRec.SuccessfulJobs
		p.Reputation.FailedJobs = repRec.FailedJobs
		p.Reputation.TotalUptime = time.Duration(repRec.TotalUptimeSeconds) * time.Second
		p.Reputation.AvgResponseTime = time.Duration(repRec.AvgResponseTimeMs) * time.Millisecond
		p.Reputation.ChallengesPassed = repRec.ChallengesPassed
		p.Reputation.ChallengesFailed = repRec.ChallengesFailed
	}

	r.logger.Info("restored provider state from store",
		"provider_id", p.ID,
		"stored_id", rec.ID,
		"trust_level", rec.TrustLevel,
		"attested", rec.Attested,
		"serial", rec.SerialNumber,
	)
	return nil
}

func providerRecordStats(raw json.RawMessage, requestsServed, tokensGenerated int64) protocol.HeartbeatStats {
	stats := protocol.HeartbeatStats{
		RequestsServed:  requestsServed,
		TokensGenerated: tokensGenerated,
	}
	if len(raw) == 0 {
		return stats
	}
	var decoded protocol.HeartbeatStats
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return stats
	}
	if decoded.RequestsServed == 0 && requestsServed != 0 {
		decoded.RequestsServed = requestsServed
	}
	if decoded.TokensGenerated == 0 && tokensGenerated != 0 {
		decoded.TokensGenerated = tokensGenerated
	}
	return decoded
}

// CompleteProviderStateRestore permits future durable identity publication only
// after provider-record lookup and RestoreProviderState finish (or no history
// exists). Missing legacy reputation is allowed; read failures leave the state
// pending. This does not grant attestation, MDA or any routing trust.
func (p *Provider) CompleteProviderStateRestore() {
	p.mu.Lock()
	p.stateRestorePending = false
	p.mu.Unlock()
}
