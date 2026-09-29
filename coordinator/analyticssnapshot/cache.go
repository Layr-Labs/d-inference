package analyticssnapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"time"
)

// Cache swaps a fully validated generation atomically. It retains a prior valid
// snapshot across refresh failures, but Get never serves it past freshness bounds.
type Cache struct {
	mu        sync.RWMutex
	snapshot  *Snapshot
	checksums map[string]string
}

// Load is the in-memory path for tests and local inspection. Serving code uses
// LoadPersistent so a process restart cannot reset its continuity fence.
func (c *Cache) Load(path string, now time.Time) error {
	return c.load(path, "", now)
}

// LoadPersistent uses an operator-initialized acceptance record on a durable
// writable mount. Missing state fails closed across coordinator restarts.
func (c *Cache) LoadPersistent(path, statePath string, now time.Time) error {
	if statePath == "" {
		return errors.New("analytics accepted state path is required")
	}
	return c.load(path, statePath, now)
}

func (c *Cache) load(path, statePath string, now time.Time) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("analytics snapshot must be a regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err = f.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("analytics snapshot must be a regular file")
	}
	s, err := Decode(f, now)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(s)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(encoded)
	checksum := hex.EncodeToString(sum[:])
	c.mu.Lock()
	defer c.mu.Unlock()
	if statePath == "" {
		if err := checkContinuity(c.snapshot, c.checksums, s, checksum); err != nil {
			return err
		}
		c.accept(s, checksum)
		return nil
	}
	return withStateLock(statePath, func(state *durableState) error {
		prior := &Snapshot{Generation: state.LatestGeneration, AsOf: state.AsOf, SourceCompleteThrough: state.SourceCompleteThrough}
		if err := checkContinuity(prior, state.Checksums, s, checksum); err != nil {
			return err
		}
		if err := checkContinuity(c.snapshot, c.checksums, s, checksum); err != nil {
			return err
		}
		if state.LatestGeneration == s.Generation &&
			(!state.AsOf.Equal(s.AsOf) || !state.SourceCompleteThrough.Equal(s.SourceCompleteThrough)) {
			return errors.New("analytics accepted generation has inconsistent cutoffs")
		}
		if state.LatestGeneration != s.Generation {
			state.LatestGeneration = s.Generation
			state.AsOf = s.AsOf
			state.SourceCompleteThrough = s.SourceCompleteThrough
			state.Checksums[s.Generation] = checksum
			if err := writeState(statePath, state); err != nil {
				return err
			}
		}
		c.snapshot = s
		c.checksums = state.Checksums
		return nil
	})
}

func checkContinuity(previous *Snapshot, checksums map[string]string, next *Snapshot, checksum string) error {
	if prior, accepted := checksums[next.Generation]; accepted && prior != checksum {
		return errors.New("analytics generation content changed")
	}
	if previous != nil && previous.Generation != "" {
		if next.AsOf.Before(previous.AsOf) || next.SourceCompleteThrough.Before(previous.SourceCompleteThrough) {
			return errors.New("analytics snapshot regressed")
		}
		if next.Generation != previous.Generation &&
			next.AsOf.Equal(previous.AsOf) && next.SourceCompleteThrough.Equal(previous.SourceCompleteThrough) {
			return errors.New("new analytics generation must advance a source cutoff")
		}
	}
	return nil
}

func (c *Cache) accept(s *Snapshot, checksum string) {
	c.snapshot = s
	if c.checksums == nil {
		c.checksums = make(map[string]string)
	}
	c.checksums[s.Generation] = checksum
}

// Get returns a shared immutable snapshot; callers must not modify it.
func (c *Cache) Get(now time.Time) (*Snapshot, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.snapshot == nil || !c.snapshot.Fresh(now) {
		return nil, false
	}
	return c.snapshot, true
}
