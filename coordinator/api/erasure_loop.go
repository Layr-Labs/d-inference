package api

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	// defaultErasureGrace is the time between the soft delete and the scrub.
	defaultErasureGrace = 30 * 24 * time.Hour
	// erasureScrubInterval is how often the loop looks for due requests.
	erasureScrubInterval = time.Hour
	// erasureScrubLease keeps a failed request from being retried before the
	// next pass, and keeps other coordinators off a request in progress.
	erasureScrubLease = time.Hour
	erasureScrubBatch = 20
)

// erasureGraceFromEnv reads EIGENINFERENCE_ERASURE_GRACE (a Go duration such
// as "720h"). Unset, invalid or negative values use defaultErasureGrace; the
// bool reports an ignored value so the caller can warn.
func erasureGraceFromEnv() (time.Duration, bool) {
	v := os.Getenv("EIGENINFERENCE_ERASURE_GRACE")
	if v == "" {
		return defaultErasureGrace, false
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < 0 {
		return defaultErasureGrace, true
	}
	return d, false
}

// StartAccountErasureLoop scrubs pending erasure requests whose grace period
// has ended: once at start, then every erasureScrubInterval.
func (s *Server) StartAccountErasureLoop(ctx context.Context) {
	saferun.Go(s.logger, "api.accountErasureLoop", func() {
		ticker := time.NewTicker(erasureScrubInterval)
		defer ticker.Stop()
		for {
			s.runDueErasures(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

// runDueErasures leases the due requests and scrubs each one.
func (s *Server) runDueErasures(ctx context.Context) {
	ids, err := s.store.LeaseDueAccountErasures(ctx, time.Now().UTC(), erasureScrubLease, erasureScrubBatch)
	if err != nil {
		s.logger.Error("account erasure: lease due requests failed", "error", err)
		return
	}
	for _, id := range ids {
		if ctx.Err() != nil {
			return
		}
		if _, err := s.scrubErasure(ctx, id); err != nil {
			s.logger.Warn("account erasure: scrub failed; retrying after the lease", "request_id", id, "error", err)
		}
	}
}

// scrubErasure runs ScrubAccount and then clears the in-memory copies of the
// account's data, which the database transaction cannot reach. A failure is
// stored on the request.
func (s *Server) scrubErasure(ctx context.Context, requestID string) (*store.ErasureResult, error) {
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
	s.registry.DisconnectAccount(accountID)
	s.trustReuseCache.forget(res.SEKeys)
	s.mdmScheduler.Forget(res.SEKeys)
	s.ledger.ForgetConsumer(accountID)
	s.invalidateAllAPIKeyCache()
	s.logger.Info("account erased", "request_id", requestID, "account_id", accountID)
	return res, nil
}
