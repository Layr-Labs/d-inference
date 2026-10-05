package erasure

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	// defaultGrace is the time between the soft delete and the scrub.
	defaultGrace = 30 * 24 * time.Hour
	// erasureScrubInterval is how often the loop looks for due requests.
	erasureScrubInterval = time.Hour
	// erasureScrubLease keeps a failed request from being retried before the
	// next pass, and keeps other coordinators off a request in progress.
	erasureScrubLease = time.Hour
	erasureScrubBatch = 20
)

// graceFromEnv reads EIGENINFERENCE_ERASURE_GRACE (a Go duration such
// as "720h"). Unset, invalid or negative values use defaultGrace; the
// bool reports an ignored value so the caller can warn.
func graceFromEnv() (time.Duration, bool) {
	v := os.Getenv("EIGENINFERENCE_ERASURE_GRACE")
	if v == "" {
		return defaultGrace, false
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < 0 {
		return defaultGrace, true
	}
	return d, false
}

// StartLoop scrubs pending erasure requests whose grace period
// has ended: once at start, then every erasureScrubInterval.
func (s *Owner) StartLoop(ctx context.Context) {
	saferun.Go(s.logger, "api.accountErasureLoop", func() {
		ticker := time.NewTicker(erasureScrubInterval)
		defer ticker.Stop()
		for {
			s.runDue(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

// runDue leases the due requests and scrubs each one.
func (s *Owner) runDue(ctx context.Context) {
	ids, err := s.store.LeaseDueAccountErasures(ctx, time.Now().UTC(), erasureScrubLease, erasureScrubBatch)
	if err != nil {
		s.logger.Error("account erasure: lease due requests failed", "error", err)
		return
	}
	for _, id := range ids {
		if ctx.Err() != nil {
			return
		}
		if _, err := s.scrub(ctx, id); err != nil {
			s.logger.Warn("account erasure: scrub failed; retrying after the lease", "request_id", id, "error", err)
		}
	}
}

// scrub runs ScrubAccount and then clears the in-memory copies of the
// account's data, which the database transaction cannot reach. A failure is
// stored on the request.
func (s *Owner) scrub(ctx context.Context, requestID string) (*store.ErasureResult, error) {
	res, err := s.store.ScrubAccount(ctx, requestID, time.Now().UTC())
	if err != nil {
		if !errors.Is(err, store.ErrErasureConflict) && !errors.Is(err, store.ErrNotFound) {
			if recErr := s.store.RecordAccountErasureFailure(ctx, requestID, err.Error()); recErr != nil {
				s.logger.Error("account erasure: record failure", "request_id", requestID, "error", recErr)
			}
		}
		return nil, err
	}
	accountID := res.Request.AccountID
	s.hooks.DisconnectAccount(accountID)
	s.hooks.ForgetSEKeys(res.SEKeys)
	s.hooks.ForgetConsumer(accountID)
	s.access.InvalidateAllAPIKeyCache()
	s.logger.Info("account erased", "request_id", requestID, "account_id", accountID)
	return res, nil
}
