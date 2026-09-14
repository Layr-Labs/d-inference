package dispatch

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// runSpeculative is the speculativeTimer.C arm of waitFirstChunk: the primary is
// slow, so dispatch a speculative backup (unless this is a prefer request being
// served by the caller's own machine) and either keep waiting for the primary
// alone (no backup available) or race primary vs backup. Returns the same outcome
// set as waitFirstChunk.
func (d *execution) runSpeculative() dispatchOutcome {
	s := d.s
	r := d.r
	provider := d.provider
	if d.onSpeculativeDispatch != nil {
		d.onSpeculativeDispatch()
	}
	if _, empty := d.pr.OnTimeEmptyCompletionIngress(); empty {
		return d.waitAccepted()
	}

	// Primary is slow. Attempt speculative backup dispatch.
	s.deps.Counters.Incr("inference.speculative_dispatch", []string{"model:" + d.model})
	s.deps.Registry().RecordWarmPoolSpeculativeStarted(d.model)

	var backupProvider *registry.Provider
	var attemptedBackupProvider *registry.Provider
	var backupPR *registry.PendingRequest
	var backupErr string
	var backupErrCode int
	backupRouteRecorded := false
	backupRouteRequestID := ""
	backupRouteAttempt := d.attempt

	// Do NOT speculatively race a paid PUBLIC backup against a prefer
	// request that is being served by the caller's OWN machine: the user
	// opted into "prefer my machine (free)", so a slow owned machine must
	// be waited on, not raced (and billed) by the public fleet. (Exclusive
	// self-route is already safe — its backup selection is owned-only and
	// returns nil when there's no other owned machine.) When the prefer
	// primary is itself a public provider (the owner owns nothing / fell
	// back), normal speculative behaviour applies.
	skipBackup := false
	if d.policy.Prefer {
		provider.Mu().Lock()
		skipBackup = d.policy.OwnerAccountID != "" && provider.AccountID == d.policy.OwnerAccountID
		provider.Mu().Unlock()
	}

	// Hedge governor (Routing v2 Phase 4): insurance must never amplify an
	// overload. A non-allow verdict suppresses the backup entirely and falls
	// through the nil-backup branch below — byte-identical to today's
	// "no backup available" path. The owner-served prefer skip above stays
	// governor-blind: it is a product rule, not a capacity decision.
	//
	// The verdict and the budget-slot increment are ONE atomic governor
	// operation (tryAcquireHedge): concurrent slow requests can no longer
	// each read the last free slot and all launch past the fleet-wide cap.
	// An acquired slot is released exactly once — below when no backup
	// actually dispatches, at race resolution otherwise.
	hedgeLaunched := false
	if !skipBackup && s.hedgeGov != nil {
		verdict, acquired := d.tryAcquireBackupHedge(provider.ID)
		d.hedgeGovernorVerdict = verdict.String()
		hedgeLaunched = acquired
		if verdict != hedgeAllow {
			s.deps.Counters.Incr("routing.hedge_governor_suppressed", []string{"model:" + d.model, "verdict:" + verdict.String()})
			s.deps.Logger().Info("speculative_backup_suppressed",
				"request_id", d.requestID,
				"primary_provider", provider.ID,
				"verdict", verdict.String(),
			)
			skipBackup = true
		}
	}

	if !skipBackup {
		d.pr.EnableSpeculativeEmptyCompletionArbitration()
		backupExclude := make(map[string]struct{}, len(d.excludeProviders)+1)
		for id := range d.excludeProviders {
			backupExclude[id] = struct{}{}
		}
		backupExclude[provider.ID] = struct{}{}

		recordBackupRoute := func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
			attemptedBackupProvider = provider
			if pr != nil {
				pr.EnableSpeculativeEmptyCompletionArbitration()
				d.configurePending(pr)
				backupRouteRecorded = true
				backupRouteRequestID = pr.RequestID
				backupRouteAttempt = pr.Attempt
			}
			d.recordRoutingDecisionFor(provider, pr, "", d.attempt, decision, "", "")
		}
		// Routing v2 W2: the backup consumes the retained plan first — the
		// next confirmed/revalidated entry, then the request's single refresh
		// — falling back to the legacy full scan only when the plan machinery
		// yields nothing (prefer-owner and legacy fleets keep their exact
		// selection behavior). The backup shares only ReceivedAt with the
		// primary's clock, as before.
		backupTiming := &registry.RequestTiming{ReceivedAt: d.timing.ReceivedAt}
		planTried := false
		backupProvider, backupPR, _, backupErr, backupErrCode, planTried =
			d.dispatchFromPlanMachinery(backupTiming, backupExclude, d.requestID, recordBackupRoute)
		if !planTried {
			backupProvider, backupPR, _, _, backupErr, backupErrCode = s.dispatchOneProvider(
				r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
				d.estimatedPromptTokens, d.deadline, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
				d.traits(),
				d.allowedProviderSerials, d.isResponsesAPI, d.policy,
				backupTiming,
				d.serviceReservation,
				d.cachePlan,
				backupExclude,
				d.attempt, d.profile, d.requestID,
				recordBackupRoute,
				d.noteProviderDispatched,
			)
		}
	}

	if backupProvider == nil {
		if hedgeLaunched {
			// The governor admitted a hedge that never dispatched — release
			// its budget slot immediately. No outcome is recorded: no race
			// ran, so there is nothing to fold into the win-rate EWMA.
			s.hedgeGov.noteHedgeResolved()
		}
		if d.pr != nil {
			d.pr.ResolveSpeculativeEmptyCompletion(true)
		}
		if backupErrCode == http.StatusRequestEntityTooLarge && attemptedBackupProvider != nil {
			d.noteProviderBodyTooLargeFor(attemptedBackupProvider, backupErr)
		}
		if backupRouteRecorded {
			d.s.deps.Observer.RouteOutcome(backupRouteRequestID, backupRouteAttempt, d.model, d.errorRoutingOutcome("error", dispatchErrorClass(backupErr), backupErrCode))
		}
		// No backup available. Keep waiting for primary with remaining deadline.
		s.deps.Logger().Info("speculative_dispatch_no_backup",
			"request_id", d.requestID,
			"primary_provider", provider.ID,
		)
		return d.waitNoBackup()
	}
	// Backup dispatched — race primary vs backup.
	if d.pr != nil {
		d.pr.UsedBackup.Store(true)
		if ap := d.pr.Profile; ap != nil {
			ap.BackupLaunched.Store(true)
		}
	}
	if backupPR != nil {
		backupPR.UsedBackup.Store(true)
	}
	s.deps.Logger().Info("speculative_dispatch",
		"request_id", d.requestID,
		"primary_provider", provider.ID,
		"backup_provider", backupProvider.ID,
		"ttft_deadline_ms", d.deadline.Milliseconds(),
		"speculative_at_ms", d.speculativeAt.Milliseconds(),
	)
	outcome := d.runRace(backupProvider, backupPR)
	if hedgeLaunched {
		// Exactly-once hedge accounting: every runRace exit — win, loss,
		// retry, client-gone, empty-completion promotion, and the failed-racer
		// sub-waits — returns through here, and BackupWon is the winner marker
		// every backup-win path sets before committing.
		s.hedgeGov.noteHedgeResolved()
		s.hedgeGov.recordHedgeOutcome(d.model, backupPR.BackupWon.Load())
	}
	return outcome
}
