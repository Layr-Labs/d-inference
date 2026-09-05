package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// persistReputation coalesces writes behind one worker per provider session.
// Taking snapshots under p.mu alone is insufficient: independent DB writes can
// arrive out of order and replace newer counters with an older snapshot.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	p.mu.Lock()
	p.reputationPersistDirty = true
	if p.reputationPersistRunning {
		p.mu.Unlock()
		return
	}
	p.reputationPersistRunning = true
	p.mu.Unlock()
	saferun.Go(r.logger, "registry.persistReputation", func() { r.flushReputation(p) })
}

func (r *Registry) flushReputation(p *Provider) {
	finished := false
	defer func() {
		// saferun catches an unexpected store panic; let later observations
		// restart persistence instead of leaving the worker flag latched forever.
		if !finished {
			p.mu.Lock()
			p.reputationPersistRunning = false
			p.reputationPersistDirty = true
			p.lastReputationPersisted = time.Time{}
			p.mu.Unlock()
		}
	}()
	for {
		p.mu.Lock()
		rep := store.ReputationRecord{
			TotalJobs: p.Reputation.TotalJobs, SuccessfulJobs: p.Reputation.SuccessfulJobs,
			FailedJobs:         p.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(p.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(p.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   p.Reputation.ChallengesPassed, ChallengesFailed: p.Reputation.ChallengesFailed,
		}
		p.reputationPersistDirty = false
		p.mu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := r.store.UpsertReputation(ctx, p.ID, rep)
		cancel()
		p.mu.Lock()
		if err != nil {
			// Retry on the next heartbeat/job/challenge rather than spin or queue
			// goroutines during a store outage. Allow the next heartbeat to retry.
			p.lastReputationPersisted = time.Time{}
			p.reputationPersistDirty = true
			p.reputationPersistRunning = false
			finished = true
			p.mu.Unlock()
			r.logger.Warn("failed to persist reputation", "provider_id", p.ID, "error", err)
			return
		}
		if !p.reputationPersistDirty {
			p.reputationPersistRunning = false
			finished = true
			p.mu.Unlock()
			return
		}
		p.mu.Unlock()
	}
}
