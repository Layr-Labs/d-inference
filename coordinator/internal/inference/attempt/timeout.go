package attempt

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type TimeoutPhase int

const (
	FirstContentTimeout TimeoutPhase = iota
	NoBackupTimeout
	AcceptedTimeout
	PreambleTimeout
)

type TimeoutDependencies struct {
	Registry    *registry.Registry
	Observation *observation.Owner
	Logger      *slog.Logger
	Cancel      func(*registry.Provider, *registry.PendingRequest) bool
	RecordError func(string, *registry.PendingRequest, int, string, string, string, ...protocol.CoordinatorInferenceErrorCause)
}

type TimeoutConfig struct {
	Model     string
	Provider  *registry.Provider
	Pending   *registry.PendingRequest
	RequestID string
	Attempt   int
}

type TimeoutResult struct {
	Claimed bool
	Failure retry.AttemptFailure
}

// Timeout owns the cancellation claim and its operational effects. The caller
// consumes the returned failure to advance its own retry/terminal state.
type Timeout struct {
	deps   TimeoutDependencies
	config TimeoutConfig
}

func NewTimeout(deps TimeoutDependencies, config TimeoutConfig) *Timeout {
	return &Timeout{deps: deps, config: config}
}

func (t *Timeout) Run(ctx context.Context, phase TimeoutPhase, budget time.Duration) TimeoutResult {
	c, d := t.config, t.deps
	if !d.Cancel(c.Provider, c.Pending) {
		return TimeoutResult{}
	}
	d.Registry.RecordWarmPoolTTFTMiss(c.Model, budget)
	if firstcontent.ProviderAttemptAttributableStall(c.Pending, budget) {
		d.RecordError(c.Provider.ID, c.Pending, http.StatusGatewayTimeout, "", "", "")
	}
	message := "timeout waiting for first response"
	if phase == AcceptedTimeout || phase == PreambleTimeout {
		message = "provider accepted but timed out before first chunk"
		if phase == PreambleTimeout {
			message = "provider sent preamble but stalled before first content"
		}
		d.Logger.Warn("provider timed out after accepting request, retrying", "request_id", c.RequestID,
			"provider_id", c.Provider.ID, "attempt", c.Attempt+1, "preamble_liveness", phase == PreambleTimeout)
		d.Observation.EmitRequest(ctx, protocol.SeverityWarn, c.RequestID, "provider accepted timeout",
			map[string]any{"provider_id": c.Provider.ID, "attempt": c.Attempt + 1, "reason": "accepted_timeout"})
	} else {
		warning := "provider timeout (full deadline), retrying"
		if phase == NoBackupTimeout {
			warning = "provider timeout (no backup), retrying"
		}
		d.Logger.Warn(warning, "request_id", c.RequestID,
			"provider_id", c.Provider.ID, "attempt", c.Attempt+1)
		d.Observation.EmitRequest(ctx, protocol.SeverityWarn, c.RequestID, "provider first-chunk timeout",
			map[string]any{"provider_id": c.Provider.ID, "attempt": c.Attempt + 1, "reason": "first_chunk_timeout"})
	}
	if d.Observation.Metrics() != nil {
		d.Observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "timeout"})
	}
	d.Observation.Incr("inference.dispatches", []string{"status:timeout"})
	return TimeoutResult{Claimed: true, Failure: retry.CoordinatorFailure(message, http.StatusGatewayTimeout)}
}
