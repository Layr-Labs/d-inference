package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

// UsageRecords returns a copy of all usage records.
func (s *MemoryStore) UsageRecords() []store.UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]store.UsageRecord, len(s.usage))
	copy(out, s.usage)
	for i := range out {
		if out[i].RequestLocation != nil {
			loc := *out[i].RequestLocation
			out[i].RequestLocation = &loc
		}
	}
	return out
}

// UsageCountSince returns the number of usage records created at or after the given time.
func (s *MemoryStore) UsageCountSince(since time.Time) (int64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		return int64(len(s.usage)), nil
	}
	var count int64
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !ts.Before(since) {
			count++
		}
	}
	return count, nil
}

// UsageTotals returns aggregated lifetime totals.
func (s *MemoryStore) UsageTotals() (store.UsageTotals, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t store.UsageTotals
	for _, r := range s.usage {
		t.Requests++
		t.PromptTokens += int64(r.PromptTokens)
		t.CompletionTokens += int64(r.CompletionTokens)
	}
	return t, nil
}

// UsageTotalsSince returns aggregate usage at or after `since`.
func (s *MemoryStore) UsageTotalsSince(since time.Time) (store.UsageTotals, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t store.UsageTotals
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) {
			continue
		}
		t.Requests++
		t.PromptTokens += int64(r.PromptTokens)
		t.CompletionTokens += int64(r.CompletionTokens)
	}
	return t, nil
}

// UsageTimeSeries buckets usage records by the requested duration since `since`.
func (s *MemoryStore) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]store.UsageBucket, error) {
	since, until, bucketSize = shared.NormalizeUsageTimeSeriesRequest(since, until, bucketSize, time.Now())
	s.mu.RLock()
	defer s.mu.RUnlock()
	buckets := make(map[int64]*store.UsageBucket)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) || !ts.Before(until) {
			continue
		}
		minute := ts.Truncate(bucketSize)
		key := minute.Unix()
		b, ok := buckets[key]
		if !ok {
			b = &store.UsageBucket{Minute: minute}
			buckets[key] = b
		}
		b.Requests++
		b.PromptTokens += int64(r.PromptTokens)
		b.CompletionTokens += int64(r.CompletionTokens)
	}
	out := make([]store.UsageBucket, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Minute.Before(out[j].Minute) })
	return shared.LimitUsageTimeSeriesBuckets(out), nil
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *MemoryStore) UsageByConsumer(consumerKey string) []store.UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []store.UsageRecord
	for _, u := range s.usage {
		if u.ConsumerKey == consumerKey {
			out = append(out, u)
		}
	}
	return out
}

// RecordUsage logs a usage event (in-memory) and updates the per-key spend
// accumulator used for cap enforcement. The record's location is copied so the
// caller cannot mutate stored state; the store assigns the timestamp.
func (s *MemoryStore) RecordUsage(rec store.UsageRecord) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if rec.RequestLocation != nil {
		cp := *rec.RequestLocation
		rec.RequestLocation = &cp
	}
	rec.Timestamp = now
	rec.CreatedAt = now
	s.usage = append(s.usage, rec)
	if rec.KeyID != "" && rec.CostMicroUSD > 0 {
		s.addKeySpendLocked(rec.KeyID, rec.CostMicroUSD, now)
	}
}
