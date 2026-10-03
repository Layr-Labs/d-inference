package api

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (d *dispatchState) recordBoundFirstContentTimeout(provider *registry.Provider, pr *registry.PendingRequest) {
	d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
	d.excludeProviders[provider.ID] = struct{}{}
	duration := d.firstContentDurationFor(pr, d.deadline)
	d.s.registry.RecordWarmPoolTTFTMiss(d.model, duration)
	if providerAttemptAttributableStall(pr, duration) {
		d.s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
	}
}

// expireBoundFirstContentRacer handles only asymmetric cutoff expiry. The
// existing simultaneous-timeout path retains its ingress arbitration and
// legacy relative preamble behavior. Call after draining both ready channels.
func (d *dispatchState) expireBoundFirstContentRacer(primary *registry.Provider, primaryPR *registry.PendingRequest, backup *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) (dispatchOutcome, bool) {
	now := time.Now()
	primaryExpired := d.boundFirstContentExpired(primaryPR, now)
	backupExpired := d.boundFirstContentExpired(backupPR, now)
	if primaryExpired == backupExpired {
		return 0, false
	}
	if primaryExpired {
		if !d.s.cancelDispatchForFirstContentTimeout(primary, primaryPR) {
			return 0, false
		}
		d.recordBoundFirstContentTimeout(primary, primaryPR)
		d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
		d.provider, d.pr, d.requestID = nil, nil, ""
		backupPR.ResolveSpeculativeEmptyCompletion(true)
		return d.racePrimaryFailedWaitBackup(backup, backupPR, backupHeld), true
	}
	if !d.s.cancelDispatchForFirstContentTimeout(backup, backupPR) {
		return 0, false
	}
	d.recordBoundFirstContentTimeout(backup, backupPR)
	primaryPR.ResolveSpeculativeEmptyCompletion(true)
	return d.raceBackupErrWaitPrimary(primary, primaryPR), true
}
