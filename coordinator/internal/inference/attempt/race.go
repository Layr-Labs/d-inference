package attempt

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// RaceAttempt is the selected transport and its uncommitted preamble. Each
// racer retains a separate buffer, including when a survivor is promoted.
type RaceAttempt struct {
	Provider   *registry.Provider
	Pending    *registry.PendingRequest
	RequestID  string
	HeldChunks []string
}

type RaceResult struct {
	Outcome             Outcome
	Attempt             RaceAttempt
	Content             *Content
	PreambleLiveness    bool
	Failure             *retry.AttemptFailure
	FailedVersion       *string
	ExcludedProviderIDs []string
	Terminal            *retry.Decision
}

type RaceConfig struct {
	Model           string
	ModelContext    int
	Deadline        time.Duration
	SpeculativeAt   time.Duration
	Clock           firstcontent.Clock
	Profile         *registry.RequestProfile
	TerminalLatched bool
}

// RaceDependencies retains the same request-wide authorities used by ordinary
// dispatch. No loser gets a separate reservation, terminal ledger or KV latch.
type RaceDependencies struct {
	Cancel            func(*registry.Provider, *registry.PendingRequest, string)
	CancelTerminal    func(*registry.Provider, *registry.PendingRequest)
	CancelTimeout     func(*registry.Provider, *registry.PendingRequest) bool
	Refund            func()
	FailedVersion     func(*registry.Provider) string
	PredictiveRefusal func(*registry.Provider)
	Committer         *ContentCommitter
	Effects           *retry.Effects
	Routes            *outcome.Recorder
	Observation       *observation.Owner
	Registry          *registry.Registry
	Retry             *retry.Controller
	Evidence          *retry.TerminalEvidence
	Backend           *backend.Latch
}

// Race owns arbitration only. Its result is handed back to dispatch before the
// accepted-content wait, retry ladder or response writer takes over.
type Race struct {
	deps   RaceDependencies
	config RaceConfig
	result RaceResult
}

func NewRace(deps RaceDependencies, config RaceConfig) *Race {
	return &Race{deps: deps, config: config}
}

func (r *Race) finish(outcome Outcome) RaceResult {
	r.result.Outcome = outcome
	return r.result
}

func (r *Race) exclude(provider *registry.Provider) {
	r.result.ExcludedProviderIDs = append(r.result.ExcludedProviderIDs, provider.ID)
}

func (r *Race) failedVersion(provider *registry.Provider) {
	version := r.deps.FailedVersion(provider)
	r.result.FailedVersion = &version
}

func (r *Race) clearAttempt(clearID bool) {
	r.result.Attempt.Provider, r.result.Attempt.Pending = nil, nil
	if clearID {
		r.result.Attempt.RequestID = ""
	}
}

func (r *Race) commit(pr *registry.PendingRequest, chunk string) {
	content := r.deps.Committer.Commit(r.config.Profile, pr, len(r.result.Attempt.HeldChunks), chunk)
	r.result.Content = &content
}

func (r *Race) commitReady(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) bool {
	content := r.deps.Committer.Buffered(r.config.Profile, pr, &r.result.Attempt.HeldChunks, msg)
	if content == nil {
		return false
	}
	r.result.Content = content
	return true
}

func (r *Race) setFailure(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	evidence := r.deps.Evidence.Observe(provider, r.config.Model, msg, r.config.ModelContext, r.deps.Backend)
	r.result.Failure = &evidence
	if failure.IsDeadlineUnreachableErrorReason(evidence.Message.ErrorReason) && r.deps.PredictiveRefusal != nil {
		r.deps.PredictiveRefusal(provider)
	}
}

func (r *Race) setTimeout(text string) {
	evidence := retry.CoordinatorFailure(text, http.StatusGatewayTimeout)
	r.result.Failure = &evidence
}

// RecordLoser preserves deterministic terminal evidence without replacing the
// surviving attempt's error. Run and the survivor handoff share this authority.
func (r *Race) RecordLoser(provider *registry.Provider, msg protocol.InferenceErrorMessage) *retry.Decision {
	msg = failure.NormalizeInternalError(msg)
	if failure.IsDeadlineUnreachableErrorReason(msg.ErrorReason) && r.deps.PredictiveRefusal != nil {
		r.deps.PredictiveRefusal(provider)
	}
	evidence := r.deps.Evidence.Observe(provider, r.config.Model, msg, r.config.ModelContext, r.deps.Backend)
	if r.config.TerminalLatched {
		return nil
	}
	decision, latched := r.deps.Retry.RecordLoser(msg, evidence.ProviderBudget)
	r.result.Terminal = &decision
	if latched {
		r.config.TerminalLatched = true
		r.deps.Backend.Pin(provider, r.config.Model)
	}
	return &decision
}

func (r *Race) noteServing(provider *registry.Provider, pr *registry.PendingRequest) {
	_, sticky := r.deps.Evidence.Select(retry.TerminalFailure{}, false)
	r.deps.Backend.Note(provider, pr, sticky || r.config.TerminalLatched)
}

func (r *Race) recordFailure(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) {
	if pr != nil {
		pr.UsedBackup.Store(true)
		r.deps.Routes.Pending(pr, outcome.PreCommitProviderErrorOutcome(pr, msg))
	}
}

func (r *Race) recordTimeout(pr *registry.PendingRequest) {
	if pr != nil {
		pr.UsedBackup.Store(true)
		r.deps.Routes.Pending(pr, outcome.PendingRouteOutcome(pr, "timeout", "first_chunk_timeout", http.StatusGatewayTimeout))
	}
}

func (r *Race) recordClientGone(pr *registry.PendingRequest) {
	if pr != nil {
		pr.UsedBackup.Store(true)
		r.deps.Routes.Pending(pr, outcome.PendingRouteOutcome(pr, "cancelled", "client_gone", 0))
	}
}

func (r *Race) noteError(provider *registry.Provider, pr *registry.PendingRequest, msg protocol.InferenceErrorMessage, held *[]string, countRetry bool) {
	if countRetry {
		r.deps.Effects.Retry(provider, pr, msg.StatusCode, msg.Error, msg.ErrorReason, msg.TerminalCause, held, msg.CoordinatorCause)
	} else {
		r.deps.Effects.ProviderError(provider, pr, msg.StatusCode, msg.Error, msg.ErrorReason, msg.TerminalCause, held, msg.CoordinatorCause)
	}
}

func (r *Race) noteTimeout() {
	if metrics := r.deps.Observation.Metrics(); metrics != nil {
		metrics.IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "timeout"})
	}
	r.deps.Observation.Incr("inference.dispatches", []string{"status:timeout"})
}

func (r *Race) backupWon() {
	r.deps.Observation.Incr("inference.speculative_win", []string{"model:" + r.config.Model})
	r.deps.Registry.RecordWarmPoolSpeculativeWon(r.config.Model)
}

func (r *Race) AwaitPrimaryEmpty(primary, backup RaceAttempt) RaceResult {
	r.result.Attempt = primary
	primary.Pending.ResolveSpeculativeEmptyCompletion(true)
	r.deps.Cancel(backup.Provider, backup.Pending, cancellation.CauseHedgeLoser)
	r.deps.Routes.SpeculativeLoser(backup.Pending)
	return r.finish(Accepted)
}

func (r *Race) AwaitBackupEmpty(primary, backup RaceAttempt) RaceResult {
	backup.Pending.ResolveSpeculativeEmptyCompletion(true)
	r.deps.Cancel(primary.Provider, primary.Pending, cancellation.CauseHedgeLoser)
	r.backupWon()
	r.deps.Routes.SpeculativeLoser(primary.Pending)
	backup.Pending.BackupWon.Store(true)
	if ap := backup.Pending.Profile; ap != nil {
		ap.BackupWon.Store(true)
		if primary.Pending != nil {
			ap.CopyPreDispatchFrom(primary.Pending.Profile)
		}
	}
	r.result.Attempt = backup
	r.result.Attempt.RequestID = backup.Pending.RequestID
	r.noteServing(backup.Provider, backup.Pending)
	return r.finish(Accepted)
}
