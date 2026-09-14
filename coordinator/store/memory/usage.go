package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/usagetime"
)

// RecordUsage appends a usage record to the in-memory log.
func (s *Store) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = append(s.usage, contracts.UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Timestamp:        time.Now(),
	})
}

// RecordPayment appends a payment record to the in-memory log.
func (s *Store) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check for duplicate tx_hash.
	for _, p := range s.payments {
		if p.TxHash == txHash && txHash != "" {
			return fmt.Errorf("duplicate tx_hash: %s", txHash)
		}
	}

	s.payments = append(s.payments, contracts.PaymentRecord{
		TxHash:           txHash,
		ConsumerAddress:  consumerAddr,
		ProviderAddress:  providerAddr,
		AmountUSD:        amountUSD,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Memo:             memo,
		CreatedAt:        time.Now(),
	})
	return nil
}

// UsageRecords returns a copy of all usage records.
func (s *Store) UsageRecords() []contracts.UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]contracts.UsageRecord, len(s.usage))
	copy(out, s.usage)
	for i := range out {
		if out[i].RequestLocation != nil {
			loc := *out[i].RequestLocation
			out[i].RequestLocation = &loc
		}
	}
	return out
}

// UsageRecordsSince returns usage records created at or after the given time.
func (s *Store) UsageRecordsSince(since time.Time) []contracts.UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		out := make([]contracts.UsageRecord, len(s.usage))
		copy(out, s.usage)
		for i := range out {
			if out[i].RequestLocation != nil {
				loc := *out[i].RequestLocation
				out[i].RequestLocation = &loc
			}
		}
		return out
	}
	var out []contracts.UsageRecord
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) {
			continue
		}
		cp := r
		if cp.RequestLocation != nil {
			loc := *cp.RequestLocation
			cp.RequestLocation = &loc
		}
		out = append(out, cp)
	}
	if out == nil {
		return []contracts.UsageRecord{}
	}
	return out
}

// UsageCountSince returns the number of usage records created at or after the given time.
func (s *Store) UsageCountSince(since time.Time) (int64, error) {
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
func (s *Store) UsageTotals() (contracts.UsageTotals, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t contracts.UsageTotals
	for _, r := range s.usage {
		t.Requests++
		t.PromptTokens += int64(r.PromptTokens)
		t.CompletionTokens += int64(r.CompletionTokens)
	}
	return t, nil
}

// UsageTotalsSince returns aggregate usage at or after `since`.
func (s *Store) UsageTotalsSince(since time.Time) (contracts.UsageTotals, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t contracts.UsageTotals
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
func (s *Store) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]contracts.UsageBucket, error) {
	since, until, bucketSize = usagetime.NormalizeRequest(since, until, bucketSize, time.Now())
	s.mu.RLock()
	defer s.mu.RUnlock()
	buckets := make(map[int64]*contracts.UsageBucket)
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
			b = &contracts.UsageBucket{Minute: minute}
			buckets[key] = b
		}
		b.Requests++
		b.PromptTokens += int64(r.PromptTokens)
		b.CompletionTokens += int64(r.CompletionTokens)
	}
	out := make([]contracts.UsageBucket, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Minute.Before(out[j].Minute) })
	return usagetime.LimitBuckets(out), nil
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *Store) UsageByConsumer(consumerKey string) []contracts.UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []contracts.UsageRecord
	for _, u := range s.usage {
		if u.ConsumerKey == consumerKey {
			out = append(out, u)
		}
	}
	return out
}

// RecordUsageWithCost logs a usage event with request ID and cost (in-memory).
func (s *Store) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation logs a usage event with request location (in-memory).
func (s *Store) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull logs a usage event with full attribution (incl. API key ID)
// and updates the per-key spend accumulator used for cap enforcement.
func (s *Store) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	s.RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, "", requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFullWithPublicModel logs usage with concrete billing model and an
// optional consumer-facing model name for usage history.
func (s *Store) RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	var locCopy *contracts.ProviderLocation
	if requestLocation != nil {
		cp := *requestLocation
		locCopy = &cp
	}
	s.usage = append(s.usage, contracts.UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		KeyID:            keyID,
		Model:            model,
		PublicModel:      publicModel,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		RequestLocation:  locCopy,
		Timestamp:        now,
		RequestID:        requestID,
		CostMicroUSD:     costMicroUSD,
	})
	if keyID != "" && costMicroUSD > 0 {
		s.addKeySpendLocked(keyID, costMicroUSD, now)
	}
}
