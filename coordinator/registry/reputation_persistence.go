package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// persistReputationThrottled persists provider reputation at most once per 30
// seconds. Used by the heartbeat path so accumulated uptime is durable across
// coordinator restarts/reconnects (reputation is reloaded from the store on
// registration) without a DB write on every heartbeat. Skipped writes are not
// lost — the in-memory TotalUptime keeps accumulating and the next throttle
// window captures it.
func (r *Registry) persistReputationThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastReputationPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastReputationPersisted = time.Now()
	p.mu.Unlock()
	r.persistReputation(p)
}

// persistReputation saves a provider's current reputation to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistReputation", func() { r.persistReputationNow(p) })
}

func (r *Registry) persistReputationNow(p *Provider) {
	p.persistMu.Lock()
	defer p.persistMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	if p.stateRestorePending {
		p.mu.Unlock()
		return
	}
	rep := providerReputationRecordLocked(p)
	p.mu.Unlock()

	if err := r.store.UpsertReputation(ctx, p.ID, rep); err != nil {
		r.logger.Warn("failed to persist reputation", "provider_id", p.ID, "error", err)
	}
}

func providerReputationRecordLocked(p *Provider) store.ReputationRecord {
	return store.ReputationRecord{TotalJobs: p.Reputation.TotalJobs, SuccessfulJobs: p.Reputation.SuccessfulJobs, FailedJobs: p.Reputation.FailedJobs,
		TotalUptimeSeconds: int64(p.Reputation.TotalUptime / time.Second), AvgResponseTimeMs: int64(p.Reputation.AvgResponseTime / time.Millisecond),
		ChallengesPassed: p.Reputation.ChallengesPassed, ChallengesFailed: p.Reputation.ChallengesFailed}
}
