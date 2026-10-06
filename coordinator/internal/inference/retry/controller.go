// Package retry bounds pre-content failover and preserves deterministic loser
// verdicts without giving race losers ownership of the surviving attempt error.
package retry

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const CapacityRetryLimit = 3
const TimeoutRetryLimit = 3

type Config struct {
	Model                  string
	ModelContext           int
	DisableClientErrorStop bool
	Observation            *observation.Owner
}

// Decision is the terminal/retry outcome consumed by dispatch and its response
// writer. Counters count distinct failed attempts, not provider health strikes.
type Decision struct {
	Stop                bool
	ClientStatusCode    int
	ClientReason        string
	ClientMessage       string
	UnservableReason    string
	DeadlineUnreachable bool
	CapacityRetries     int
	TimeoutRetries      int
}

type Controller struct {
	cfg              Config
	capacityRetries  int
	timeoutRetries   int
	clientCode       int
	clientReason     string
	clientMessage    string
	unservableReason string
}

func New(cfg Config) *Controller { return &Controller{cfg: cfg} }

func (c *Controller) decision(stop, deadline bool) Decision {
	return Decision{Stop: stop, ClientStatusCode: c.clientCode,
		ClientReason: c.clientReason, ClientMessage: c.clientMessage,
		UnservableReason: c.unservableReason, DeadlineUnreachable: deadline,
		CapacityRetries: c.capacityRetries, TimeoutRetries: c.timeoutRetries}
}

func (c *Controller) latchTemplate(reason, src string) bool {
	if !TemplateRejectEnabled() || !failure.IsJinjaTemplateErrorReason(reason) {
		return false
	}
	tags := []string{"model:" + c.cfg.Model, "code:422", "reason:" + failure.NormalizeReason(reason)}
	if src != "" {
		tags = append(tags, "src:"+src)
	}
	c.cfg.Observation.Incr("routing.dispatch_client_error_stop", tags)
	c.clientCode = http.StatusUnprocessableEntity
	c.clientReason = "template_render_failed"
	c.clientMessage = TemplateRejectMessage
	return true
}

func (c *Controller) Decide(msg protocol.InferenceErrorMessage, providerBudget int64) Decision {
	if c.unservableReason != "" || c.clientCode != 0 {
		return c.decision(true, false)
	}
	if !c.cfg.DisableClientErrorStop && outcome.IsTerminalClientErrorCode(msg.StatusCode) {
		c.cfg.Observation.Incr("routing.dispatch_client_error_stop", []string{"model:" + c.cfg.Model, "code:" + strconv.Itoa(msg.StatusCode)})
		c.clientCode = msg.StatusCode
		return c.decision(true, false)
	}
	if c.latchTemplate(msg.ErrorReason, "") {
		return c.decision(true, false)
	}
	if msg.StatusCode == http.StatusGatewayTimeout && !failure.IsTypedTimeout504Cause(msg.TerminalCause) {
		c.timeoutRetries++
		if c.timeoutRetries >= TimeoutRetryLimit {
			c.cfg.Observation.Incr("routing.first_chunk_timeout_ladder_capped", []string{"model:" + c.cfg.Model})
			return c.decision(true, false)
		}
		return c.decision(false, false)
	}
	kind := rejection.Classify(msg.ErrorReason, msg.Error, providerBudget, c.cfg.ModelContext, msg.RejectionReason)
	if kind != rejection.DeadlineUnreachable && msg.TerminalCause == failure.TerminalCauseAdmissionTimeout {
		kind = rejection.TransientCapacity
	}
	switch kind {
	case rejection.DeterministicUnservable:
		c.cfg.Observation.Incr("routing.dispatch_to_capacity_503", []string{"model:" + c.cfg.Model, "reason:deterministic"})
		c.unservableReason = "oversized_request"
		return c.decision(true, false)
	case rejection.DeadlineUnreachable:
		return c.decision(false, true)
	case rejection.TransientCapacity:
		if failure.IsDrainingErrorReason(msg.ErrorReason) {
			c.cfg.Observation.Incr("routing.dispatch_to_capacity_503", []string{"model:" + c.cfg.Model, "reason:draining"})
			return c.decision(false, false)
		}
		c.cfg.Observation.Incr("routing.dispatch_to_capacity_503", []string{"model:" + c.cfg.Model, "reason:transient"})
		c.capacityRetries++
		if c.capacityRetries >= CapacityRetryLimit {
			c.unservableReason = "oversized_request"
			return c.decision(true, false)
		}
		return c.decision(false, false)
	default:
		return c.decision(false, false)
	}
}

// RecordLoser returns latched only when this loser owns a deterministic terminal
// verdict. The dispatch owner uses it to latch that provider's slot attribution.
func (c *Controller) RecordLoser(msg protocol.InferenceErrorMessage, providerBudget int64) (decision Decision, latched bool) {
	msg = failure.NormalizeInternalError(msg)
	if msg.AvailableTokenBudget != nil {
		providerBudget = *msg.AvailableTokenBudget
	}
	if c.unservableReason != "" || c.clientCode != 0 {
		return c.decision(true, false), false
	}
	if !c.cfg.DisableClientErrorStop && outcome.IsTerminalClientErrorCode(msg.StatusCode) {
		c.cfg.Observation.Incr("routing.dispatch_client_error_stop", []string{"model:" + c.cfg.Model, "code:" + strconv.Itoa(msg.StatusCode), "src:race_loser"})
		c.clientCode = msg.StatusCode
		return c.decision(true, false), true
	}
	if c.latchTemplate(msg.ErrorReason, "race_loser") {
		return c.decision(true, false), true
	}
	switch rejection.Classify(msg.ErrorReason, msg.Error, providerBudget, c.cfg.ModelContext, msg.RejectionReason) {
	case rejection.DeadlineUnreachable:
	case rejection.DeterministicUnservable:
		c.cfg.Observation.Incr("routing.dispatch_to_capacity_503", []string{"model:" + c.cfg.Model, "reason:deterministic"})
		c.unservableReason = "oversized_request"
		return c.decision(true, false), true
	}
	return c.decision(false, false), false
}
