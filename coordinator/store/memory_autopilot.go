package store

import (
	"context"
	"encoding/json"
	"sort"
	"time"
)

func (s *MemoryStore) RecordAutopilot(_ context.Context, records []AutopilotRecord) error {
	for _, r := range records {
		if err := validateAutopilotRecord(r); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.autopilotRecords == nil {
		s.autopilotRecords = map[string]AutopilotRecord{}
	}
	for _, r := range records {
		key := r.CommandID + ":" + r.Phase
		if _, exists := s.autopilotRecords[key]; exists {
			continue
		}
		raw, _ := json.Marshal(r)
		var copy AutopilotRecord
		_ = json.Unmarshal(raw, &copy)
		s.autopilotRecords[key] = copy
	}
	return nil
}
func (s *MemoryStore) AutopilotRecords(_ context.Context, since time.Time, limit int) ([]AutopilotRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	out := []AutopilotRecord{}
	for _, r := range s.autopilotRecords {
		if !r.At.Before(since) {
			raw, _ := json.Marshal(r)
			var copy AutopilotRecord
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
