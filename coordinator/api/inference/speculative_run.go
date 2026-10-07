package inference

import (
	"net/http"

	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	inferhedge "github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Run dispatches a backup when policy and capacity permit, then selects the
// corresponding real wait. An admitted hedge holds its slot across all race
// sub-waits and releases it exactly once, without recording a non-race outcome.
func (p *Speculative) Run(in SpeculativeRequest, waits SpeculativeWaits) SpeculativeResult {
	s, d, provider := p.s, in.Dispatch, in.Primary
	if p.attempted {
		return SpeculativeResult{Outcome: waits.NoBackup(nil), GovernorVerdict: p.verdict}
	}
	p.attempted = true
	if _, empty := in.Pending.OnTimeEmptyCompletionIngress(); empty {
		return SpeculativeResult{Outcome: waits.Accepted(), GovernorVerdict: p.verdict}
	}

	s.observation.Incr("inference.speculative_dispatch", []string{"model:" + d.Model})
	s.registry.RecordWarmPoolSpeculativeStarted(d.Model)

	var backupProvider, attemptedBackupProvider *registry.Provider
	var backupPR *registry.PendingRequest
	var backupErr string
	var backupErrCode int
	backupRouteRecorded := false
	backupRouteRequestID := ""
	backupRouteAttempt := d.Attempt

	// An owner-served prefer request must never race a paid public backup.
	// This product rule is deliberately governor-blind.
	skipBackup := false
	if d.Scope.PreferOwner {
		provider.Mu().Lock()
		skipBackup = d.Scope.OwnerAccountID != "" && provider.AccountID == d.Scope.OwnerAccountID
		provider.Mu().Unlock()
	}

	hedgeLaunched := false
	if !skipBackup && s.hedgeGov != nil {
		verdict, acquired := s.NewDispatcher().AcquireHedge(s.hedgeGov, d.Model, in.Pending, d.Exclusions.IDs(), provider.ID)
		p.verdict = verdict.String()
		hedgeLaunched = acquired
		if verdict != inferhedge.Allow {
			s.observation.Incr("routing.hedge_governor_suppressed", []string{"model:" + d.Model, "verdict:" + verdict.String()})
			s.logger.Info("speculative_backup_suppressed",
				"request_id", in.RequestID,
				"primary_provider", provider.ID,
				"verdict", verdict.String(),
			)
			skipBackup = true
		}
	}

	if !skipBackup {
		in.Pending.EnableSpeculativeEmptyCompletionArbitration()
		backupExclude := providerdispatch.NewExclusions(d.Exclusions.IDs()...)
		backupExclude.Exclude(provider.ID)
		recordBackupRoute := func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
			attemptedBackupProvider = provider
			if pr != nil {
				pr.EnableSpeculativeEmptyCompletionArbitration()
				providerdispatch.ConfigurePending(pr, d.Request, in.Metadata)
				backupRouteRecorded = true
				backupRouteRequestID = pr.RequestID
				backupRouteAttempt = pr.Attempt
			}
			s.recordRoutingDecision(d, provider, pr, "", d.Attempt, decision, "", "")
		}
		// The retained plan and its single refresh precede the legacy scan.
		// Only ReceivedAt is shared with the primary's timing.
		backupInput := d
		backupInput.Timing = &registry.RequestTiming{ReceivedAt: d.Timing.ReceivedAt}
		backupInput.Exclusions = backupExclude
		backupInput.BackupOf = in.RequestID
		backupInput.RecordRoute = recordBackupRoute
		backup, selection := p.plan.Next(backupInput)
		if !selection.Tried() {
			backup = p.plan.Dispatch(backupInput,
				func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
					return s.registry.ReserveProviderWithPlan(d.Model, pr, excludeIDs...)
				}, true)
		}
		backupProvider, backupPR = backup.Provider, backup.Pending
		backupErr, backupErrCode = backup.Error, backup.ErrorCode
	}

	if backupProvider == nil {
		if hedgeLaunched {
			s.hedgeGov.Resolve()
		}
		if in.Pending != nil {
			in.Pending.ResolveSpeculativeEmptyCompletion(true)
		}
		var overflow *PrimaryHistory
		failure := in.Failure
		if backupErrCode == http.StatusRequestEntityTooLarge && attemptedBackupProvider != nil {
			history := (PrimaryHistory{}).ProviderBodyRejected(d.Body, attemptedBackupProvider, backupErr, d.Exclusions)
			overflow = &history
			failure = history.Failure
		}
		if backupRouteRecorded {
			s.updateInferenceRouteOutcomeWithModel(backupRouteRequestID, backupRouteAttempt, d.Model,
				retry.ErrorRouteOutcome(in.Pending, "error", dispatchErrorClass(backupErr), protocol.InferenceErrorMessage{
					Error: failure.Message.Error, ErrorReason: failure.Message.ErrorReason, StatusCode: backupErrCode,
				}))
		}
		s.logger.Info("speculative_dispatch_no_backup",
			"request_id", in.RequestID,
			"primary_provider", provider.ID,
		)
		return SpeculativeResult{Outcome: waits.NoBackup(overflow), GovernorVerdict: p.verdict}
	}

	if in.Pending != nil {
		in.Pending.UsedBackup.Store(true)
		if ap := in.Pending.Profile; ap != nil {
			ap.BackupLaunched.Store(true)
		}
	}
	if backupPR != nil {
		backupPR.UsedBackup.Store(true)
	}
	s.logger.Info("speculative_dispatch",
		"request_id", in.RequestID,
		"primary_provider", provider.ID,
		"backup_provider", backupProvider.ID,
		"ttft_deadline_ms", d.Deadline.Milliseconds(),
		"speculative_at_ms", in.SpeculativeAt.Milliseconds(),
	)
	outcome := waits.Race(backupProvider, backupPR)
	if hedgeLaunched {
		s.hedgeGov.Resolve()
		s.hedgeGov.RecordOutcome(d.Model, backupPR.BackupWon.Load())
	}
	return SpeculativeResult{Outcome: outcome, GovernorVerdict: p.verdict}
}
