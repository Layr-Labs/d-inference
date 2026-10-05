package settlement

import (
	"log/slog"
	"time"

	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const DefaultGrace = 30 * time.Second

// Controller parks disconnected requests while the owning lifecycle retains
// refund authority. Holder is the injected one-shot terminal handoff.
type Controller struct {
	Holder     *Holder
	Grace      time.Duration
	Refund     func(*registry.PendingRequest, string) bool
	Outcome    func(*registry.PendingRequest, *store.InferenceRouteOutcome)
	NoTerminal func(string)
	ClientGone func(string, int, string, string)
	Logger     *slog.Logger
}

func (c *Controller) Hold(pr *registry.PendingRequest) {
	if pr == nil || pr.IsReservationFinalized() {
		return
	}
	if c.Holder == nil {
		if c.Refund(pr, "no_terminal_after_cancel:"+pr.RequestID) {
			c.Outcome(pr, routeoutcome.NoTerminalAfterCancelOutcome(pr))
			c.NoTerminal(pr.Model)
			c.ClientGone(pr.Model, pr.EstimatedPromptTokens, "", "after_commit")
		}
		return
	}
	grace := c.Grace
	if grace <= 0 {
		grace = DefaultGrace
	}
	c.Holder.Hold(pr, grace, func(expired *registry.PendingRequest) {
		if c.Refund(expired, "no_terminal_after_cancel:"+expired.RequestID) {
			c.Outcome(expired, routeoutcome.NoTerminalAfterCancelOutcome(expired))
			c.NoTerminal(expired.Model)
			c.ClientGone(expired.Model, expired.EstimatedPromptTokens, "", "after_commit")
			c.Logger.Warn("no terminal from provider after cancel — refunded reservation", "request_id", expired.RequestID)
		}
	})
}

func (c *Controller) Claim(requestID string) *registry.PendingRequest {
	if c.Holder == nil {
		return nil
	}
	return c.Holder.Claim(requestID)
}
