package sandboxcontrol

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	DefaultCommandPayloadRetention = 24 * time.Hour
	MaximumCommandPayloadRetention = 30 * 24 * time.Hour
	commandPayloadSweepInterval    = time.Minute
)

// A zero option preserves the compiled default used by bare test/config
// literals. Deployment configuration rejects nonpositive explicit durations.
func WithCommandPayloadRetention(retention time.Duration) Option {
	return func(c *Controller) {
		if retention > 0 && retention <= MaximumCommandPayloadRetention {
			c.commandPayloadRetention = retention
		}
	}
}

func (c *Controller) sweepCommandPayloads(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, dispatchTimeout)
	defer cancel()
	retention := c.commandPayloadRetention
	if retention <= 0 {
		retention = DefaultCommandPayloadRetention
	}
	now := c.now().UTC()
	count, err := c.store.RedactSandboxCommandPayloads(ctx, now.Add(-retention), now, store.MaxSandboxPayloadRedactionBatch)
	if err == nil && count > 0 && c.logger != nil {
		c.logger.Info("sandbox command payloads expired", "count", count)
	}
	return err
}
