package store

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/ownership"
)

// RustTerminalStore is an in-memory implementation of ownership.TerminalStore
// for unit tests of Go rollback terminal ingest.
type RustTerminalStore struct {
	mu    sync.Mutex
	byKey map[string]*ownership.TerminalDisposition
	late  []ownership.TerminalIngest
}

func NewRustTerminalStore() *RustTerminalStore {
	return &RustTerminalStore{byKey: make(map[string]*ownership.TerminalDisposition)}
}

func (s *RustTerminalStore) Put(jobID, attemptID, digest, disposition string, ack json.RawMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byKey[attemptID+"|"+digest] = &ownership.TerminalDisposition{
		Disposition: disposition,
		JobID:       jobID,
		AckPayload:  ack,
	}
}

func (s *RustTerminalStore) LookupRustTerminal(ctx context.Context, attemptID, digest string) (*ownership.TerminalDisposition, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.byKey[attemptID+"|"+digest]
	if d == nil {
		return nil, nil
	}
	cp := *d
	return &cp, nil
}

func (s *RustTerminalStore) RecordLateTerminal(ctx context.Context, t ownership.TerminalIngest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.late = append(s.late, t)
	return nil
}

func (s *RustTerminalStore) LateCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.late)
}
