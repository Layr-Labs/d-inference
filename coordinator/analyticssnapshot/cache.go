package analyticssnapshot

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"time"
)

// Cache swaps a fully validated generation atomically. It retains a prior valid
// snapshot across refresh failures, but Get never serves it past freshness bounds.
type Cache struct {
	mu       sync.RWMutex
	snapshot *Snapshot
	checksum [32]byte
}

func (c *Cache) Load(path string, now time.Time) error {
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
	checksum := sha256.Sum256(encoded)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.snapshot != nil && c.snapshot.Generation == s.Generation && c.checksum != checksum {
		return errors.New("analytics generation content changed")
	}
	if c.snapshot != nil && (s.AsOf.Before(c.snapshot.AsOf) || s.SourceCompleteThrough.Before(c.snapshot.SourceCompleteThrough)) {
		return errors.New("analytics snapshot regressed")
	}
	c.snapshot = s
	c.checksum = checksum
	return nil
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
