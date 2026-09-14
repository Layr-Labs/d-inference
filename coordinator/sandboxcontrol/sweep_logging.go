package sandboxcontrol

import (
	"context"
	"errors"
	"time"
)

const sweepFailureLogInterval = time.Minute

// Called only by the single sweeper goroutine. Failed phases keep retrying;
// logging once a minute per phase prevents an outage from flooding telemetry.
func (c *Controller) recordSweepResult(phase string, err error) {
	if c.logger == nil || errors.Is(err, context.Canceled) {
		return
	}
	if c.sweepFailures == nil {
		c.sweepFailures = make(map[string]time.Time)
	}
	lastWarning, failed := c.sweepFailures[phase]
	if err == nil {
		if failed {
			delete(c.sweepFailures, phase)
			c.logger.Info("sandbox sweep recovered", "phase", phase)
		}
		return
	}
	now := c.now().UTC()
	if !failed || !now.Before(lastWarning.Add(sweepFailureLogInterval)) {
		c.sweepFailures[phase] = now
		c.logger.Warn("sandbox sweep failed; durable work will retry", "phase", phase, "error", err)
	}
}
