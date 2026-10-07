// Package pendingload owns session-scoped outstanding model-load reservations.
package pendingload

import (
	"sync"
	"time"
)

const (
	TTL           = 2 * time.Minute
	DrainBackoff  = 30 * time.Second
	MemoryBackoff = 30 * time.Second
)

// Key uses the live session ID, not the provider's stable fault identity.
type Key struct {
	ProviderID string
	ModelID    string
}

// Reservation identifies the exact command attempt captured before delivery.
// Values returned by the ledger never grant access to its stored entries.
type Reservation struct {
	ExpiresAt time.Time
	StartedAt time.Time
}

// Ledger is ready to use at its zero value. Callers retain their outer registry
// critical sections for operations spanning reservations and provider state.
type Ledger struct {
	mu      sync.RWMutex
	entries map[Key]Reservation
}

func (l *Ledger) Reserve(key Key, expiresAt, startedAt time.Time) Reservation {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.entries == nil {
		l.entries = make(map[Key]Reservation)
	}
	reservation := Reservation{ExpiresAt: expiresAt, StartedAt: startedAt}
	l.entries[key] = reservation
	return reservation
}

// Backoff changes the cooldown without restarting an existing load's duration.
func (l *Ledger) Backoff(key Key, now time.Time, backoff time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.entries == nil {
		l.entries = make(map[Key]Reservation)
	}
	reservation := l.entries[key]
	reservation.ExpiresAt = now.Add(backoff)
	if reservation.StartedAt.IsZero() {
		reservation.StartedAt = now
	}
	l.entries[key] = reservation
}

func (l *Ledger) Lookup(key Key) (Reservation, bool) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	reservation, ok := l.entries[key]
	return reservation, ok
}

// HasProvider includes expired entries until a planner explicitly reaps them.
func (l *Ledger) HasProvider(providerID string) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	for key := range l.entries {
		if key.ProviderID == providerID && key.ModelID != "" {
			return true
		}
	}
	return false
}

// Count includes every stored reservation, even an expired or unstarted one.
func (l *Ledger) Count() int {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return len(l.entries)
}

// CountStartedBeforeExpiry is the outstanding legacy-load budget for Autopilot.
// Unlike Count it excludes expiry equality and entries without a start time.
func (l *Ledger) CountStartedBeforeExpiry(now time.Time) int {
	l.mu.RLock()
	defer l.mu.RUnlock()
	count := 0
	for _, reservation := range l.entries {
		if now.Before(reservation.ExpiresAt) && !reservation.StartedAt.IsZero() {
			count++
		}
	}
	return count
}

func (l *Ledger) Drop(key Key) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, key)
}

func (l *Ledger) DropProvider(providerID string) int {
	return l.DropIf(func(key Key) bool { return key.ProviderID == providerID }, nil)
}

// DropIf applies catalog/session invalidation and records activity after each
// removal. Both callbacks run under the ledger lock and must not reenter it.
func (l *Ledger) DropIf(matches func(Key) bool, dropped func(Key)) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	count := 0
	for key := range l.entries {
		if matches(key) {
			delete(l.entries, key)
			if dropped != nil {
				dropped(key)
			}
			count++
		}
	}
	return count
}

// Expire preserves expiry equality. Activity is recorded before each removal;
// the callback runs under the ledger lock and must not reenter it.
func (l *Ledger) Expire(now time.Time, expiring func(Key)) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for key, reservation := range l.entries {
		if now.After(reservation.ExpiresAt) {
			if expiring != nil {
				expiring(key)
			}
			delete(l.entries, key)
		}
	}
}
