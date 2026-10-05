// Package lockfile serializes trust journal operations across goroutines and processes.
package lockfile

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

var processMu sync.Mutex

// WithProcessLock holds both the process mutex and the on-disk advisory lock
// through fn, including the caller's durable write and directory sync.
func WithProcessLock(path string, timeout time.Duration, fn func() error) (err error) {
	processMu.Lock()
	defer processMu.Unlock()

	lock, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("open trust-reuse journal lock: %w", err)
	}
	defer Close(lock, &err)
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("secure trust-reuse journal lock permissions: %w", err)
	}
	deadline := time.Now().Add(timeout)
	for {
		err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, unix.EWOULDBLOCK) || time.Now().After(deadline) {
			return fmt.Errorf("lock trust-reuse journal: %w", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	return fn()
}

// Close propagates a lock-file close failure without masking an earlier error.
func Close(lock *os.File, err *error) {
	if closeErr := lock.Close(); closeErr != nil && *err == nil {
		*err = fmt.Errorf("close trust-reuse journal lock: %w", closeErr)
	}
}
