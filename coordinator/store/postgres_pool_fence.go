package store

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
)

const coordinatorMutationLockName = "darkbloom-coordinator-mutation"
const coordinatorOwnershipLockName = "darkbloom-coordinator-owner"

// poolOwnershipFence serializes every checked-out serving connection against
// an ownership handoff. A successor takes the exclusive mutation lock before
// advancing the epoch; serving connections hold its shared form until they are
// returned to the pool. The epoch check therefore cannot race the operation
// that follows it.
type poolOwnershipFence struct {
	active  atomic.Bool
	healthy atomic.Bool
	mu      sync.RWMutex
	ownerID string
	epoch   int64
	onLost  func()
}

func (f *poolOwnershipFence) activate(ownerID string, epoch int64) {
	f.mu.Lock()
	f.ownerID = ownerID
	f.epoch = epoch
	f.mu.Unlock()
	f.healthy.Store(true)
	f.active.Store(true)
}

func (f *poolOwnershipFence) markLost() {
	f.healthy.Store(false)
	f.mu.RLock()
	onLost := f.onLost
	f.mu.RUnlock()
	if f.active.Load() && onLost != nil {
		onLost()
	}
}

func (f *poolOwnershipFence) beforeAcquire(ctx context.Context, conn *pgx.Conn) bool {
	if !f.active.Load() {
		return true
	}
	if _, err := conn.Exec(ctx,
		`SELECT pg_advisory_lock_shared(hashtextextended($1, 0))`,
		coordinatorMutationLockName,
	); err != nil {
		return false
	}
	valid := f.healthy.Load()
	var acquiredOwnership bool
	if valid {
		// A false result can mean either our dedicated connection still owns
		// the primary lock or a successor acquired it and is waiting for the
		// exclusive mutation lock. In the latter case this checkout is still
		// linearized before handoff: its shared lock prevents the successor
		// from advancing the epoch until after the checkout returns.
		if err := conn.QueryRow(ctx,
			`SELECT pg_try_advisory_lock(hashtextextended($1, 0))`,
			coordinatorOwnershipLockName,
		).Scan(&acquiredOwnership); err != nil {
			valid = false
		} else if acquiredOwnership {
			valid = false
			_, _ = conn.Exec(context.Background(),
				`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
				coordinatorOwnershipLockName,
			)
			f.markLost()
		}
	}
	f.mu.RLock()
	ownerID, epoch := f.ownerID, f.epoch
	f.mu.RUnlock()
	if valid && ownerID == "" {
		if err := conn.QueryRow(ctx,
			`SELECT NOT EXISTS (
				SELECT 1 FROM public.schema_migrations
				WHERE id = 'coordinator_ownership_activated'
			)`,
		).Scan(&valid); err != nil {
			valid = false
		}
	} else if valid {
		if err := conn.QueryRow(ctx,
			`SELECT EXISTS (
				SELECT 1 FROM public.coordinator_ownership
				WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
			)`,
			ownerID, epoch,
		).Scan(&valid); err != nil {
			valid = false
		}
	}
	if !valid {
		_, _ = conn.Exec(context.Background(),
			`SELECT pg_advisory_unlock_shared(hashtextextended($1, 0))`,
			coordinatorMutationLockName,
		)
	}
	return valid
}

func (f *poolOwnershipFence) afterRelease(conn *pgx.Conn) bool {
	if !f.active.Load() {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var unlocked bool
	err := conn.QueryRow(ctx,
		`SELECT pg_advisory_unlock_shared(hashtextextended($1, 0))`,
		coordinatorMutationLockName,
	).Scan(&unlocked)
	return err == nil
}
