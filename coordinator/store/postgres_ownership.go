package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

// ActivateCoordinatorOwnership preserves the single-active coordinator fence
// without coupling its operational writes to NewPostgres schema validation.
// Callers must invoke it before serving or performing startup recovery.
func (s *PostgresStore) ActivateCoordinatorOwnership(ctx context.Context, enabled bool) error {
	if s.ownershipConn != nil {
		if enabled {
			return nil
		}
		return errors.New("store: coordinator ownership is already active")
	}

	var ownershipActivated bool
	if err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM schema_migrations WHERE id = 'coordinator_ownership_activated'
		)`,
	).Scan(&ownershipActivated); err != nil {
		return fmt.Errorf("store: read coordinator ownership activation: %w", err)
	}
	if ownershipActivated && !enabled {
		return errors.New("store: coordinator ownership was activated and cannot be disabled")
	}
	if !enabled {
		return nil
	}

	ownershipConn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire coordinator ownership connection: %w", err)
	}
	var ownsCoordinator bool
	if err := ownershipConn.QueryRow(ctx,
		`SELECT pg_try_advisory_lock(hashtextextended('darkbloom-coordinator-owner', 0))`,
	).Scan(&ownsCoordinator); err != nil {
		ownershipConn.Release()
		return fmt.Errorf("store: acquire coordinator ownership lock: %w", err)
	}
	if !ownsCoordinator {
		ownershipConn.Release()
		return errors.New("store: coordinator ownership is already held by another process")
	}

	s.ownershipConn = ownershipConn
	s.ownershipEnabled = true
	s.ownershipHealthy.Store(true)
	s.ownershipLost = make(chan struct{})
	s.ownershipStop = make(chan struct{})
	s.ownershipDone = make(chan struct{})
	s.ownershipID = uuid.NewString()

	if err := ownershipConn.QueryRow(ctx,
		`INSERT INTO coordinator_ownership (singleton, epoch, owner_id, acquired_at)
		 VALUES (TRUE, 1, $1, NOW())
		 ON CONFLICT (singleton) DO UPDATE SET
			epoch = coordinator_ownership.epoch + 1,
			owner_id = EXCLUDED.owner_id,
			acquired_at = NOW()
		 RETURNING epoch`,
		s.ownershipID,
	).Scan(&s.ownershipEpoch); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: advance coordinator ownership epoch: %w", err)
	}
	if _, err := ownershipConn.Exec(ctx,
		`INSERT INTO schema_migrations (id)
		 VALUES ('coordinator_ownership_activated')
		 ON CONFLICT (id) DO NOTHING`,
	); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: persist coordinator ownership activation: %w", err)
	}

	go s.monitorOwnership()
	return nil
}

func (s *PostgresStore) releaseFailedOwnership(ctx context.Context) {
	if s.ownershipConn == nil {
		return
	}
	_, _ = s.ownershipConn.Exec(
		ctx,
		`SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))`,
	)
	s.ownershipConn.Release()
	s.ownershipConn = nil
	s.ownershipEnabled = false
	s.ownershipHealthy.Store(false)
}
