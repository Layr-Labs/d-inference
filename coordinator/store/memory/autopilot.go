package memory

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) RecordAutopilot(_ context.Context, records []store.AutopilotRecord) error {
	for _, r := range records {
		if err := shared.ValidateAutopilotRecord(r); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.autopilotRecords == nil {
		s.autopilotRecords = map[string]store.AutopilotRecord{}
	}
	for _, r := range records {
		key := r.CommandID + ":" + r.Phase
		if _, exists := s.autopilotRecords[key]; exists {
			continue
		}
		raw, _ := json.Marshal(r)
		var copy store.AutopilotRecord
		_ = json.Unmarshal(raw, &copy)
		s.autopilotRecords[key] = copy
	}
	return nil
}

func (s *MemoryStore) AutopilotRecords(_ context.Context, since time.Time, limit int) ([]store.AutopilotRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	out := []store.AutopilotRecord{}
	for _, r := range s.autopilotRecords {
		if !r.At.Before(since) {
			raw, _ := json.Marshal(r)
			var copy store.AutopilotRecord
			_ = json.Unmarshal(raw, &copy)
			out = append(out, copy)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
