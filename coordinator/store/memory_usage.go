package store

import (
	"fmt"
	"sort"
	"time"
)

// RecordUsage appends a usage record to the in-memory log.
func (s *MemoryStore) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Timestamp:        time.Now(),
	})
}

// RecordPayment appends a payment record to the in-memory log.
func (s *MemoryStore) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check for duplicate tx_hash.
	for _, p := range s.payments {
		if p.TxHash == txHash && txHash != "" {
			return fmt.Errorf("duplicate tx_hash: %s", txHash)
		}
	}

	s.payments = append(s.payments, PaymentRecord{
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
func (s *MemoryStore) UsageRecords() []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]UsageRecord, len(s.usage))
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
func (s *MemoryStore) UsageRecordsSince(since time.Time) []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		out := make([]UsageRecord, len(s.usage))
		copy(out, s.usage)
		for i := range out {
			if out[i].RequestLocation != nil {
				loc := *out[i].RequestLocation
				out[i].RequestLocation = &loc
			}
		}
		return out
	}
	var out []UsageRecord
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
		return []UsageRecord{}
	}
	return out
}

// UsageCountSince returns the number of usage records created at or after the given time.
func (s *MemoryStore) UsageCountSince(since time.Time) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if since.IsZero() {
		return int64(len(s.usage))
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
	return count
}

// UsageTotals returns aggregated lifetime totals.
func (s *MemoryStore) UsageTotals() UsageTotals {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t UsageTotals
	for _, r := range s.usage {
		t.Requests++
		t.PromptTokens += int64(r.PromptTokens)
		t.CompletionTokens += int64(r.CompletionTokens)
	}
	return t
}

// UsageTimeSeries buckets usage records by minute since `since`.
func (s *MemoryStore) UsageTimeSeries(since time.Time) []UsageBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()
	buckets := make(map[int64]*UsageBucket)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if ts.Before(since) {
			continue
		}
		minute := ts.Truncate(time.Minute)
		key := minute.Unix()
		b, ok := buckets[key]
		if !ok {
			b = &UsageBucket{Minute: minute}
			buckets[key] = b
		}
		b.Requests++
		b.PromptTokens += int64(r.PromptTokens)
		b.CompletionTokens += int64(r.CompletionTokens)
	}
	out := make([]UsageBucket, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Minute.Before(out[j].Minute) })
	return out
}

// Leaderboard ranks accounts by the chosen metric across provider_earnings.
func (s *MemoryStore) Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	limit = NormalizeLeaderboardLimit(limit)
	agg := make(map[string]*LeaderboardRow)
	for _, e := range s.providerEarnings {
		if e.AccountID == "" {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		row, ok := agg[e.AccountID]
		if !ok {
			row = &LeaderboardRow{AccountID: e.AccountID}
			agg[e.AccountID] = row
		}
		row.EarningsMicroUSD += e.AmountMicroUSD
		row.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		row.Jobs++
	}
	rows := make([]LeaderboardRow, 0, len(agg))
	for _, r := range agg {
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		switch metric {
		case LeaderboardTokens:
			return rows[i].Tokens > rows[j].Tokens
		case LeaderboardJobs:
			return rows[i].Jobs > rows[j].Jobs
		default:
			return rows[i].EarningsMicroUSD > rows[j].EarningsMicroUSD
		}
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

// NetworkTotals aggregates metrics across all earnings.
func (s *MemoryStore) NetworkTotals(since time.Time) NetworkTotalsRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t NetworkTotalsRow
	seen := make(map[string]struct{})
	for _, e := range s.providerEarnings {
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		t.EarningsMicroUSD += e.AmountMicroUSD
		t.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		t.Jobs++
		if e.AccountID != "" {
			if _, ok := seen[e.AccountID]; !ok {
				seen[e.AccountID] = struct{}{}
				t.ActiveAccounts++
			}
		}
	}
	return t
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *MemoryStore) UsageByConsumer(consumerKey string) []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []UsageRecord
	for _, u := range s.usage {
		if u.ConsumerKey == consumerKey {
			out = append(out, u)
		}
	}
	return out
}

// RecordUsageWithCost logs a usage event with request ID and cost (in-memory).
func (s *MemoryStore) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation logs a usage event with request location (in-memory).
func (s *MemoryStore) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull logs a usage event with full attribution (incl. API key ID)
// and updates the per-key spend accumulator used for cap enforcement.
func (s *MemoryStore) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	var locCopy *ProviderLocation
	if requestLocation != nil {
		cp := *requestLocation
		locCopy = &cp
	}
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		KeyID:            keyID,
		Model:            model,
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

// UsageLocationBuckets returns approximate request-origin aggregates (in-memory).
func (s *MemoryStore) UsageLocationBuckets(since time.Time) []UsageLocationBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type bucketKey struct {
		City        string
		Region      string
		RegionCode  string
		Country     string
		CountryCode string
	}
	type agg struct {
		key                              bucketKey
		latSum, lngSum                   float64
		coordCount                       int
		requests, promptTok, completeTok int64
		providers                        map[string]struct{}
	}
	buckets := make(map[bucketKey]*agg)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !since.IsZero() && ts.Before(since) {
			continue
		}
		if r.RequestLocation == nil {
			continue
		}
		loc := r.RequestLocation
		k := bucketKey{
			City:        loc.City,
			Region:      loc.Region,
			RegionCode:  loc.RegionCode,
			Country:     loc.Country,
			CountryCode: loc.CountryCode,
		}
		b, ok := buckets[k]
		if !ok {
			b = &agg{key: k, providers: make(map[string]struct{})}
			buckets[k] = b
		}
		b.requests++
		b.promptTok += int64(r.PromptTokens)
		b.completeTok += int64(r.CompletionTokens)
		if loc.Latitude != 0 || loc.Longitude != 0 {
			b.latSum += loc.Latitude
			b.lngSum += loc.Longitude
			b.coordCount++
		}
		if r.ProviderID != "" {
			b.providers[r.ProviderID] = struct{}{}
		}
	}
	out := make([]UsageLocationBucket, 0, len(buckets))
	for _, b := range buckets {
		var lat, lng float64
		if b.coordCount > 0 {
			lat = b.latSum / float64(b.coordCount)
			lng = b.lngSum / float64(b.coordCount)
		}
		out = append(out, UsageLocationBucket{
			City:             b.key.City,
			Region:           b.key.Region,
			RegionCode:       b.key.RegionCode,
			Country:          b.key.Country,
			CountryCode:      b.key.CountryCode,
			Latitude:         lat,
			Longitude:        lng,
			Requests:         b.requests,
			PromptTokens:     b.promptTok,
			CompletionTokens: b.completeTok,
			Providers:        len(b.providers),
		})
	}
	return out
}

// UsageFlowBuckets aggregates directional consumer→provider flows in memory.
// providerLocs supplies live provider locations from the registry; the store's
// own providerRecords are used as a fallback for disconnected providers.
func (s *MemoryStore) UsageFlowBuckets(since time.Time, providerLocs map[string]*ProviderLocation) []UsageFlowBucket {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type flowKey struct {
		cCity, cRegion, cCountry string
		pCity, pRegion, pCountry string
	}
	type agg struct {
		b         UsageFlowBucket
		cLatSum   float64
		cLngSum   float64
		cCoordCnt int
		pLatSum   float64
		pLngSum   float64
		pCoordCnt int
	}

	// Resolve provider location: prefer live registry, fall back to stored records.
	resolveProviderLoc := func(providerID string) *ProviderLocation {
		if loc, ok := providerLocs[providerID]; ok && loc != nil {
			return loc
		}
		if rec, ok := s.providerRecords[providerID]; ok {
			return rec.Location
		}
		return nil
	}

	flows := make(map[flowKey]*agg)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !since.IsZero() && ts.Before(since) {
			continue
		}
		if r.RequestLocation == nil {
			continue
		}
		pLoc := resolveProviderLoc(r.ProviderID)
		if pLoc == nil {
			continue
		}
		cLoc := r.RequestLocation
		k := flowKey{
			cCity: cLoc.City, cRegion: cLoc.RegionCode, cCountry: cLoc.CountryCode,
			pCity: pLoc.City, pRegion: pLoc.RegionCode, pCountry: pLoc.CountryCode,
		}
		fa, ok := flows[k]
		if !ok {
			fa = &agg{b: UsageFlowBucket{
				ConsumerCity: cLoc.City, ConsumerRegion: cLoc.Region,
				ConsumerRegionCode: cLoc.RegionCode, ConsumerCountry: cLoc.Country,
				ConsumerCountryCode: cLoc.CountryCode,
				ProviderCity:        pLoc.City, ProviderRegion: pLoc.Region,
				ProviderRegionCode: pLoc.RegionCode, ProviderCountry: pLoc.Country,
				ProviderCountryCode: pLoc.CountryCode,
			}}
			flows[k] = fa
		}
		fa.b.Requests++
		fa.b.PromptTokens += int64(r.PromptTokens)
		fa.b.CompletionTokens += int64(r.CompletionTokens)
		if cLoc.Latitude != 0 || cLoc.Longitude != 0 {
			fa.cLatSum += cLoc.Latitude
			fa.cLngSum += cLoc.Longitude
			fa.cCoordCnt++
		}
		if pLoc.Latitude != 0 || pLoc.Longitude != 0 {
			fa.pLatSum += pLoc.Latitude
			fa.pLngSum += pLoc.Longitude
			fa.pCoordCnt++
		}
	}

	out := make([]UsageFlowBucket, 0, len(flows))
	for _, fa := range flows {
		b := fa.b
		if fa.cCoordCnt > 0 {
			b.ConsumerLatitude = fa.cLatSum / float64(fa.cCoordCnt)
			b.ConsumerLongitude = fa.cLngSum / float64(fa.cCoordCnt)
		}
		if fa.pCoordCnt > 0 {
			b.ProviderLatitude = fa.pLatSum / float64(fa.pCoordCnt)
			b.ProviderLongitude = fa.pLngSum / float64(fa.pCoordCnt)
		}
		out = append(out, b)
	}
	return out
}
