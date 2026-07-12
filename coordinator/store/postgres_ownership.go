package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ActivateCoordinatorOwnership preserves the single-active coordinator fence
// without coupling its operational writes to NewPostgres schema validation.
// Callers must invoke it before serving or performing startup recovery.
func (s *PostgresStore) ActivateCoordinatorOwnership(ctx context.Context, enabled bool) error {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
	}
	if s.ownershipConn != nil {
		if enabled == s.ownershipEpochActive {
			return nil
		}
		return errors.New("store: coordinator ownership is already active")
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
	s.ownershipEpochActive = enabled
	s.ownershipHealthy.Store(true)
	s.ownershipLost = make(chan struct{})
	s.ownershipStop = make(chan struct{})
	s.ownershipDone = make(chan struct{})
	if _, err := ownershipConn.Exec(ctx,
		`SELECT pg_advisory_lock(hashtextextended($1, 0))`,
		coordinatorMutationLockName,
	); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: acquire coordinator mutation handoff lock: %w", err)
	}
	mutationLocked := true
	defer func() {
		if mutationLocked && s.ownershipConn != nil {
			_, _ = ownershipConn.Exec(context.Background(),
				`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
				coordinatorMutationLockName,
			)
		}
	}()

	var ownershipActivated bool
	if err := ownershipConn.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM public.schema_migrations
			WHERE id = 'coordinator_ownership_activated'
		)`,
	).Scan(&ownershipActivated); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: read coordinator ownership activation: %w", err)
	}
	if ownershipActivated && !enabled {
		s.releaseFailedOwnership(ctx)
		return errors.New("store: coordinator ownership was activated and cannot be disabled")
	}
	if !enabled {
		s.poolFence.activate("", 0)
		if _, err := ownershipConn.Exec(ctx,
			`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
			coordinatorMutationLockName,
		); err != nil {
			s.releaseFailedOwnership(ctx)
			return fmt.Errorf("store: release coordinator mutation handoff lock: %w", err)
		}
		mutationLocked = false
		go s.monitorOwnership()
		return nil
	}

	s.ownershipID = "go:" + uuid.NewString()
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
		`INSERT INTO public.schema_migrations (id)
		 VALUES ('coordinator_ownership_activated')
		 ON CONFLICT (id) DO NOTHING`,
	); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: persist coordinator ownership activation: %w", err)
	}
	s.poolFence.activate(s.ownershipID, s.ownershipEpoch)
	if _, err := ownershipConn.Exec(ctx,
		`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
		coordinatorMutationLockName,
	); err != nil {
		s.releaseFailedOwnership(ctx)
		return fmt.Errorf("store: release coordinator mutation handoff lock: %w", err)
	}
	mutationLocked = false

	go s.monitorOwnership()
	return nil
}

func (s *PostgresStore) releaseFailedOwnership(ctx context.Context) {
	if s.ownershipConn == nil {
		return
	}
	_, _ = s.ownershipConn.Exec(
		ctx,
		`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
		coordinatorMutationLockName,
	)
	_, _ = s.ownershipConn.Exec(
		ctx,
		`SELECT pg_advisory_unlock(hashtextextended('darkbloom-coordinator-owner', 0))`,
	)
	s.ownershipConn.Release()
	s.ownershipConn = nil
	s.ownershipEnabled = false
	s.ownershipEpochActive = false
	s.ownershipHealthy.Store(false)
	if s.poolFence != nil {
		s.poolFence.markLost()
	}
}
