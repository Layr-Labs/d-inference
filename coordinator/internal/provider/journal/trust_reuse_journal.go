package journal

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/journal/lockfile"
	"github.com/google/uuid"
	"golang.org/x/sys/unix"
)

const (
	envTrustReuseRevocationJournal = env.EnvPrefix + "_TRUST_REUSE_REVOCATION_JOURNAL_PATH"
	trustReuseJournalFilename      = "trust-reuse-hard-untrust.v1.jsonl"
	trustReuseJournalVersion       = 1
	trustReuseJournalMaxEntries    = 4096
	trustReuseJournalMaxBytes      = 1 << 20
	trustReuseJournalMaxLineBytes  = 512
	trustReuseJournalLockTimeout   = 5 * time.Second
)

// hardUntrustJournalEntry is one durable pending hard-untrust revocation.
// SEPubKey (added within journal version 1 as an optional field) carries the
// plaintext SE public key so crash replay can create a missing tombstone row
// even when the identity never had a provider_trust_reuse row at revocation
// time. Legacy digest-only entries (written before the field existed) still
// load and replay against listed rows; only row-less convergence needs the key.
type Entry struct {
	Version      int    `json:"v"`
	SEKeySHA256  string `json:"se_key_sha256"`
	RevocationID string `json:"revocation_event_id"`
	SEPubKey     string `json:"se_pub_key,omitempty"`
}

type Journal interface {
	Initialize() error
	Load() ([]Entry, error)
	Append(Entry) ([]Entry, error)
	Remove(Entry) ([]Entry, error)
	Path() string
}

type File struct {
	path     string
	lockPath string
}

type AuthorityLock struct {
	file *os.File
}

// AcquireAuthority holds exclusive coordinator ownership for this journal.
func (j *File) AcquireAuthority() (*AuthorityLock, error) {
	lockPath := j.path + ".authority"
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
	return &AuthorityLock{file: lock}, nil
}

func (l *AuthorityLock) Close() error {
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

func ResolveTrustReuseRevocationJournalPath() string {
	if override := strings.TrimSpace(os.Getenv(envTrustReuseRevocationJournal)); override != "" {
		return override
	}
	root := env.FirstNonEmpty(
		os.Getenv("USER_PERSISTENT_DATA_PATH"),
		"/mnt/disks/userdata",
	)
	return filepath.Join(root, "coordinator", trustReuseJournalFilename)
}

func NewFile(path string) *File {
	return &File{path: path, lockPath: path + ".lock"}
}

func (j *File) Path() string { return j.path }

func HashSEPublicKey(seKey string) string {
	digest := sha256.Sum256([]byte(seKey))
	return hex.EncodeToString(digest[:])
}

func NewEntry(seKey, revocationEventID string) Entry {
	return Entry{
		Version:      trustReuseJournalVersion,
		SEKeySHA256:  HashSEPublicKey(seKey),
		RevocationID: revocationEventID,
		SEPubKey:     seKey,
	}
}

func (j *File) Initialize() error {
	if strings.TrimSpace(j.path) == "" {
		return errors.New("trust-reuse revocation journal path is empty")
	}
	dir := filepath.Dir(j.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create trust-reuse journal directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("secure trust-reuse journal directory permissions: %w", err)
	}
	return j.withProcessLock(func() error {
		info, err := os.Lstat(j.path)
		switch {
		case errors.Is(err, os.ErrNotExist):
			f, createErr := os.OpenFile(j.path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
			if createErr != nil {
				return fmt.Errorf("create trust-reuse journal: %w", createErr)
			}
			if syncErr := f.Sync(); syncErr != nil {
				_ = f.Close()
				return fmt.Errorf("fsync new trust-reuse journal: %w", syncErr)
			}
			if closeErr := f.Close(); closeErr != nil {
				return fmt.Errorf("close new trust-reuse journal: %w", closeErr)
			}
			if syncErr := syncDirectory(dir); syncErr != nil {
				return fmt.Errorf("fsync trust-reuse journal directory: %w", syncErr)
			}
		case err != nil:
			return fmt.Errorf("inspect trust-reuse journal: %w", err)
		case !info.Mode().IsRegular():
			return fmt.Errorf("trust-reuse journal is not a regular file")
		default:
			if chmodErr := os.Chmod(j.path, 0o600); chmodErr != nil {
				return fmt.Errorf("secure trust-reuse journal permissions: %w", chmodErr)
			}
		}
		_, err = j.loadUnlocked()
		return err
	})
}

func (j *File) Load() ([]Entry, error) {
	var entries []Entry
	err := j.withProcessLock(func() error {
		var err error
		entries, err = j.loadUnlocked()
		return err
	})
	return entries, err
}

func (j *File) Append(entry Entry) ([]Entry, error) {
	if err := validateHardUntrustJournalEntry(entry); err != nil {
		return nil, err
	}
	var entries []Entry
	err := j.withProcessLock(func() error {
		var err error
		entries, err = j.loadUnlocked()
		if err != nil {
			return err
		}
		for _, current := range entries {
			if current == entry {
				return nil
			}
		}
		if len(entries) >= trustReuseJournalMaxEntries {
			return fmt.Errorf("trust-reuse revocation journal entry limit reached")
		}
		encoded, err := json.Marshal(entry)
		if err != nil {
			return fmt.Errorf("encode trust-reuse journal entry: %w", err)
		}
		encoded = append(encoded, '\n')
		if len(encoded) > trustReuseJournalMaxLineBytes {
			return fmt.Errorf("trust-reuse revocation journal entry exceeds line limit")
		}
		info, err := os.Stat(j.path)
		if err != nil {
			return fmt.Errorf("stat trust-reuse journal before append: %w", err)
		}
		if info.Size()+int64(len(encoded)) > trustReuseJournalMaxBytes {
			return fmt.Errorf("trust-reuse revocation journal byte limit reached")
		}
		f, err := os.OpenFile(j.path, os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return fmt.Errorf("open trust-reuse journal for append: %w", err)
		}
		if err := writeAll(f, encoded); err != nil {
			_ = f.Close()
			return fmt.Errorf("append trust-reuse journal: %w", err)
		}
		if err := f.Sync(); err != nil {
			_ = f.Close()
			return fmt.Errorf("fsync trust-reuse journal append: %w", err)
		}
		if err := f.Close(); err != nil {
			return fmt.Errorf("close trust-reuse journal append: %w", err)
		}
		entries = append(entries, entry)
		return nil
	})
	return entries, err
}

func (j *File) Remove(entry Entry) ([]Entry, error) {
	if err := validateHardUntrustJournalEntry(entry); err != nil {
		return nil, err
	}
	var remaining []Entry
	err := j.withProcessLock(func() error {
		entries, err := j.loadUnlocked()
		if err != nil {
			return err
		}
		remaining = make([]Entry, 0, len(entries))
		found := false
		for _, current := range entries {
			if current == entry {
				found = true
				continue
			}
			remaining = append(remaining, current)
		}
		if !found {
			return nil
		}
		return j.rewriteUnlocked(remaining)
	})
	return remaining, err
}

func (j *File) withProcessLock(fn func() error) (err error) {
	return lockfile.WithProcessLock(j.lockPath, trustReuseJournalLockTimeout, fn)
}

func (j *File) loadUnlocked() ([]Entry, error) {
	f, err := os.Open(j.path)
	if err != nil {
		return nil, fmt.Errorf("open trust-reuse journal: %w", err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat trust-reuse journal: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("trust-reuse journal is not a regular file")
	}
	if info.Size() > trustReuseJournalMaxBytes {
		return nil, fmt.Errorf("trust-reuse revocation journal exceeds byte limit")
	}

	entries := make([]Entry, 0)
	seen := make(map[Entry]struct{})
	scanner := bufio.NewScanner(io.LimitReader(f, trustReuseJournalMaxBytes+1))
	scanner.Buffer(make([]byte, 256), trustReuseJournalMaxLineBytes)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := scanner.Bytes()
		if len(line) == 0 {
			return nil, fmt.Errorf("malformed trust-reuse journal line %d: empty line", lineNumber)
		}
		var entry Entry
		decoder := json.NewDecoder(bytes.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&entry); err != nil {
			return nil, fmt.Errorf("malformed trust-reuse journal line %d: %w", lineNumber, err)
		}
		if err := decoder.Decode(&struct{}{}); err != io.EOF {
			return nil, fmt.Errorf("malformed trust-reuse journal line %d: trailing data", lineNumber)
		}
		if err := validateHardUntrustJournalEntry(entry); err != nil {
			return nil, fmt.Errorf("malformed trust-reuse journal line %d: %w", lineNumber, err)
		}
		if _, duplicate := seen[entry]; duplicate {
			continue
		}
		seen[entry] = struct{}{}
		entries = append(entries, entry)
		if len(entries) > trustReuseJournalMaxEntries {
			return nil, fmt.Errorf("trust-reuse revocation journal entry limit exceeded")
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read trust-reuse journal: %w", err)
	}
	return entries, nil
}

func validateHardUntrustJournalEntry(entry Entry) error {
	if entry.Version != trustReuseJournalVersion {
		return fmt.Errorf("unsupported journal version %d", entry.Version)
	}
	if len(entry.SEKeySHA256) != sha256.Size*2 || strings.ToLower(entry.SEKeySHA256) != entry.SEKeySHA256 {
		return errors.New("invalid SE key digest")
	}
	if _, err := hex.DecodeString(entry.SEKeySHA256); err != nil {
		return errors.New("invalid SE key digest")
	}
	parsed, err := uuid.Parse(entry.RevocationID)
	if err != nil || parsed.String() != entry.RevocationID {
		return errors.New("invalid revocation event ID")
	}
	// Optional plaintext SE key (row-less replay) must bind to the digest, so
	// a corrupted/edited journal line cannot redirect a revocation replay.
	if entry.SEPubKey != "" && HashSEPublicKey(entry.SEPubKey) != entry.SEKeySHA256 {
		return errors.New("SE key does not match digest")
	}
	return nil
}

func (j *File) rewriteUnlocked(entries []Entry) error {
	dir := filepath.Dir(j.path)
	temp, err := os.CreateTemp(dir, ".trust-reuse-hard-untrust-*.tmp")
	if err != nil {
		return fmt.Errorf("create trust-reuse journal temp file: %w", err)
	}
	tempPath := temp.Name()
	cleanup := func() {
		_ = temp.Close()
		_ = os.Remove(tempPath)
	}
	if err := temp.Chmod(0o600); err != nil {
		cleanup()
		return fmt.Errorf("secure trust-reuse journal temp file: %w", err)
	}
	for _, entry := range entries {
		encoded, err := json.Marshal(entry)
		if err != nil {
			cleanup()
			return fmt.Errorf("encode trust-reuse journal rewrite: %w", err)
		}
		encoded = append(encoded, '\n')
		if err := writeAll(temp, encoded); err != nil {
			cleanup()
			return fmt.Errorf("write trust-reuse journal rewrite: %w", err)
		}
	}
	if err := temp.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("fsync trust-reuse journal rewrite: %w", err)
	}
	if err := temp.Close(); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("close trust-reuse journal rewrite: %w", err)
	}
	if err := os.Rename(tempPath, j.path); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("replace trust-reuse journal: %w", err)
	}
	if err := syncDirectory(dir); err != nil {
		return fmt.Errorf("fsync trust-reuse journal directory: %w", err)
	}
	return nil
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
