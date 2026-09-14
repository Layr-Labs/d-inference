package trustreuse

import (
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"sync"
	"time"
)

var hardUntrustJournalProcessMu sync.Mutex

type trustAuthorityLock struct {
	file *os.File
}

func acquireTrustAuthorityLock(path string) (*trustAuthorityLock, error) {
	lockPath := path + ".authority"
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open trust authority lock: %w", err)
	}
	if err := os.Chmod(lockPath, 0o600); err != nil {
		_ = lock.Close()
		return nil, fmt.Errorf("secure trust authority lock permissions: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lock.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, errors.New("another coordinator owns the trust authority")
		}
		return nil, fmt.Errorf("acquire trust authority lock: %w", err)
	}
	return &trustAuthorityLock{file: lock}, nil
}

func (l *trustAuthorityLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	fd := int(l.file.Fd())
	unlockErr := unix.Flock(fd, unix.LOCK_UN)
	closeErr := l.file.Close()
	l.file = nil
	if unlockErr != nil {
		return fmt.Errorf("release trust authority lock: %w", unlockErr)
	}
	return closeErr
}

func (j *fileHardUntrustJournal) withProcessLock(fn func() error) (err error) {
	hardUntrustJournalProcessMu.Lock()
	defer hardUntrustJournalProcessMu.Unlock()

	lock, err := os.OpenFile(j.lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("open trust-reuse journal lock: %w", err)
	}
	// A failed Close on the lock file can mask a lost flock release; surface it
	// when the guarded operation itself succeeded.
	defer closeJournalLock(lock, &err)
	if err := os.Chmod(j.lockPath, 0o600); err != nil {
		return fmt.Errorf("secure trust-reuse journal lock permissions: %w", err)
	}
	deadline := time.Now().Add(trustReuseJournalLockTimeout)
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

// closeJournalLock closes the journal lock file and propagates the Close error
// through the caller's named return when no earlier error is already being
// returned — a swallowed Close failure could mask a lost flock release.
func closeJournalLock(lock *os.File, err *error) {
	if closeErr := lock.Close(); closeErr != nil && *err == nil {
		*err = fmt.Errorf("close trust-reuse journal lock: %w", closeErr)
	}
}
