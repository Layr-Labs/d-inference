package registry

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// MergeVerifiedMachineHistory adds a canonical historical baseline after fresh
// credential/account verification. Unlike registration restoration, it may run
// after this connection has served: it preserves all live security evidence,
// account linkage, raw session counters and work earned meanwhile. A baseline
// already applied at registration (or an earlier canonical merge) is never
// applied again. rec must come from account-scoped ResolveMachineContinuity.
func (r *Registry) MergeVerifiedMachineHistory(ctx context.Context, p *Provider, rec *store.ProviderRecord) error {
	if p == nil || rec == nil {
		return nil
	}
	p.mu.Lock()
	account, restored := p.AccountID, p.historyRestored
	p.mu.Unlock()
	if account == "" || rec.AccountID != account {
		return errors.New("machine history account mismatch")
	}
	if restored {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var reputation *store.ReputationRecord
	if r.store != nil {
		var err error
		reputation, err = r.store.GetReputation(ctx, rec.ID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return fmt.Errorf("machine history reputation: %w", err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return context.Canceled
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AccountID != account {
		return errors.New("machine history account changed")
	}
	if p.historyRestored {
		return nil
	}
	historical := providerRecordStats(rec.LifetimeStats, rec.LifetimeRequestsServed, rec.LifetimeTokensGenerated)
	applyHeartbeatStatsDelta(&p.Stats, protocol.HeartbeatStats{}, historical)
	if reputation != nil {
		p.Reputation.TotalJobs += max(0, reputation.TotalJobs)
		p.Reputation.SuccessfulJobs += max(0, reputation.SuccessfulJobs)
		p.Reputation.FailedJobs += max(0, reputation.FailedJobs)
		p.Reputation.TotalUptime += time.Duration(max(0, reputation.TotalUptimeSeconds)) * time.Second
		p.Reputation.ChallengesPassed += max(0, reputation.ChallengesPassed)
		p.Reputation.ChallengesFailed += max(0, reputation.ChallengesFailed)
		if p.Reputation.AvgResponseTime == 0 {
			p.Reputation.AvgResponseTime = time.Duration(max(0, reputation.AvgResponseTimeMs)) * time.Millisecond
		}
	}
	p.historyRestored = true
	return nil
}
