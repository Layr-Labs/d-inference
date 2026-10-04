package attempt

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (r *Race) recordBoundTimeout(provider *registry.Provider, pr *registry.PendingRequest) {
	r.recordTimeout(pr)
	r.exclude(provider)
	duration := r.config.Clock.ForPending(pr).Duration(r.config.Deadline)
	r.deps.Registry.RecordWarmPoolTTFTMiss(r.config.Model, duration)
	if firstcontent.ProviderAttemptAttributableStall(pr, duration) {
		r.deps.Effects.RecordError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
	}
}

// expireBoundRacer runs after both ready-content drains. Only the expired
// renderer loses ownership; the survivor keeps its independently bound clock.
func (r *Race) expireBoundRacer(ctx context.Context, primary, backup RaceAttempt) (RaceResult, bool) {
	primaryExpired := r.config.Clock.ForPending(primary.Pending).BoundExpired()
	backupExpired := r.config.Clock.ForPending(backup.Pending).BoundExpired()
	if primaryExpired == backupExpired {
		return RaceResult{}, false
	}
	if primaryExpired {
		if !r.deps.CancelTimeout(primary.Provider, primary.Pending) {
			return RaceResult{}, false
		}
		r.recordBoundTimeout(primary.Provider, primary.Pending)
		r.setTimeout("timeout waiting for first response")
		r.clearAttempt(true)
		backup.Pending.ResolveSpeculativeEmptyCompletion(true)
		return r.waitBackup(ctx, backup), true
	}
	if !r.deps.CancelTimeout(backup.Provider, backup.Pending) {
		return RaceResult{}, false
	}
	r.recordBoundTimeout(backup.Provider, backup.Pending)
	primary.Pending.ResolveSpeculativeEmptyCompletion(true)
	return r.waitPrimary(ctx, primary.Provider, primary.Pending, false), true
}
