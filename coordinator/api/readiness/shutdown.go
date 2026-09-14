package readiness

import (
	"context"
	"os"
	"strings"
	"time"
)

// DefaultDrainGrace is how long SIGTERM shutdown waits for in-flight inference
// requests to finish (after entering drain mode) before forcing the HTTP server
// to shut down. Streaming responses can run well past the old 15s Shutdown
// deadline, so the default is generous.
//
// It matches the coordinator's inferenceTimeout (10 minutes): streaming requests
// reset that timeout on each chunk and non-streaming requests may validly take
// the full budget, so a shorter default would still cut healthy generations
// during an otherwise graceful restart. Overridable via EIGENINFERENCE_DRAIN_GRACE.
const DefaultDrainGrace = 600 * time.Second

// drainGracePollInterval is how often WaitForInflightZero re-checks the in-flight
// count while waiting for requests to finish.
const drainGracePollInterval = 100 * time.Millisecond

// DrainGraceFromEnv returns the configured SIGTERM drain grace. It reads
// EIGENINFERENCE_DRAIN_GRACE (a Go duration string, e.g. "90s"); an unset, empty,
// or invalid value falls back to DefaultDrainGrace. An explicit "0" disables the
// wait so shutdown calls http.Server.Shutdown immediately.
func DrainGraceFromEnv() time.Duration {
	raw := strings.TrimSpace(os.Getenv("EIGENINFERENCE_DRAIN_GRACE"))
	if raw == "" {
		return DefaultDrainGrace
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d < 0 {
		return DefaultDrainGrace
	}
	return d
}

// WaitForInflightZero blocks until the in-flight inference count reaches 0 or ctx
// is done (its deadline elapses or it is cancelled), polling periodically. It
// returns true if inflight reached 0 (clean drain) and false if it gave up with
// requests still in flight.
//
// Used by SIGTERM shutdown to let already-admitted (possibly long-streaming)
// requests finish before calling http.Server.Shutdown. It never blocks forever:
// the caller bounds the wait with a context deadline (EIGENINFERENCE_DRAIN_GRACE)
// and then proceeds to Shutdown regardless — Shutdown's own deadline is the hard
// backstop. Pair with SetDraining(true) first so no NEW requests are admitted
// while we wait, otherwise the count may never settle.
func (s *Controller) WaitForInflightZero(ctx context.Context) bool {
	if s.Inflight() == 0 {
		return true
	}
	ticker := time.NewTicker(drainGracePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return s.Inflight() == 0
		case <-ticker.C:
			if s.Inflight() == 0 {
				return true
			}
		}
	}
}
