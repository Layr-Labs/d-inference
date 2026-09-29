package analyticssnapshot

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

const maxStateBytes = 64 << 20

// The operator creates the empty version-1 file on a persistent writable mount
// before enabling snapshot mode. Missing or corrupt state fails closed; a
// coordinator restart must never silently bootstrap from a rolled-back pointer.
type durableState struct {
	Version               int               `json:"version"`
	LatestGeneration      string            `json:"latest_generation"`
	AsOf                  time.Time         `json:"as_of"`
	SourceCompleteThrough time.Time         `json:"source_complete_through"`
	Checksums             map[string]string `json:"checksums"`
}

func readState(path string) (*durableState, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("analytics accepted state unavailable: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() > maxStateBytes {
		return nil, errors.New("analytics accepted state is not a private bounded regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var state durableState
	dec := json.NewDecoder(io.LimitReader(f, maxStateBytes+1))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&state); err != nil {
		return nil, fmt.Errorf("decode analytics accepted state: %w", err)
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return nil, errors.New("analytics accepted state has trailing content")
	}
	if err := state.validate(); err != nil {
		return nil, err
	}
	return &state, nil
}

func (s *durableState) validate() error {
	if s.Version != 1 || s.Checksums == nil {
		return errors.New("invalid analytics accepted state version or checksums")
	}
	if s.LatestGeneration == "" {
		if len(s.Checksums) != 0 || !s.AsOf.IsZero() || !s.SourceCompleteThrough.IsZero() {
			return errors.New("invalid empty analytics accepted state")
		}
		return nil
	}
	if s.AsOf.IsZero() || s.SourceCompleteThrough.IsZero() || s.AsOf.After(s.SourceCompleteThrough) {
		return errors.New("invalid analytics accepted source cutoff")
	}
	if _, ok := s.Checksums[s.LatestGeneration]; !ok {
		return errors.New("latest analytics generation is absent from accepted history")
	}
	for generation, digest := range s.Checksums {
		if generation == "" || len(generation) > 128 || len(digest) != 64 {
			return errors.New("invalid analytics accepted generation identity")
		}
		if _, err := hex.DecodeString(digest); err != nil {
			return errors.New("invalid analytics accepted generation checksum")
		}
	}
	return nil
}

func withStateLock(path string, fn func(*durableState) error) error {
	if !filepath.IsAbs(path) {
		return errors.New("analytics accepted state path must be absolute")
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return fmt.Errorf("lock analytics accepted state: %w", err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	state, err := readState(path)
	if err != nil {
		return err
	}
	return fn(state)
}

func writeState(path string, state *durableState) error {
	if err := state.validate(); err != nil {
		return err
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	if len(raw) > maxStateBytes {
		return errors.New("analytics accepted state exceeds size limit")
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".analytics-accepted-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := io.Copy(tmp, bytes.NewReader(raw)); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
