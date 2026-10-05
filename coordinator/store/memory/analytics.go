package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Leaderboard ranks accounts by the chosen metric, splitting inference work from
// network rewards. Base-reward rows live in provider_earnings for provider-facing
// history, but count as reward earnings here so they do not inflate work/jobs.
// Reward-only ledger accounts (e.g. consumer-only referrers) do not appear.
func (s *MemoryStore) Leaderboard(metric store.LeaderboardMetric, since time.Time, limit int) ([]store.LeaderboardRow, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	agg := make(map[string]*store.LeaderboardRow)
	rowFor := func(accountID string) *store.LeaderboardRow {
		row, ok := agg[accountID]
		if !ok {
			row = &store.LeaderboardRow{AccountID: accountID}
			agg[accountID] = row
		}
		return row
	}
	// Provider earnings rows: inference work plus base_reward rows.
	for _, e := range s.history.ProviderEarnings {
		if e.AccountID == "" {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		row := rowFor(e.AccountID)
		if e.Model == "base_reward" {
			row.RewardEarningsMicroUSD += e.AmountMicroUSD
			continue
		}
		row.WorkEarningsMicroUSD += e.AmountMicroUSD
		row.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		row.Jobs++
	}
	// Non-inference reward earnings — credited only to provider accounts (those
	// that already have inference work above). Reward-only accounts (e.g.
	// consumer-only referrers) are intentionally not added to the provider
	// leaderboard.
	for _, e := range s.history.LedgerEntries {
		if e.AccountID == "" || !store.IsRewardLedgerType(e.Type) {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if row, ok := agg[e.AccountID]; ok {
			row.RewardEarningsMicroUSD += e.AmountMicroUSD
		}
	}
	rows := make([]store.LeaderboardRow, 0, len(agg))
	for _, r := range agg {
		r.EarningsMicroUSD = r.WorkEarningsMicroUSD + r.RewardEarningsMicroUSD
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		switch metric {
		case store.LeaderboardTokens:
			if rows[i].Tokens != rows[j].Tokens {
				return rows[i].Tokens > rows[j].Tokens
			}
		case store.LeaderboardJobs:
			if rows[i].Jobs != rows[j].Jobs {
				return rows[i].Jobs > rows[j].Jobs
			}
		default:
			if rows[i].EarningsMicroUSD != rows[j].EarningsMicroUSD {
				return rows[i].EarningsMicroUSD > rows[j].EarningsMicroUSD
			}
		}
		return rows[i].AccountID < rows[j].AccountID
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

// NetworkTotals aggregates provider earnings, splitting inference work from
// rewards. Base-reward rows count as reward earnings, not work/jobs/tokens.
// Ledger rewards are only counted for accounts that also have provider earnings
// rows in the window, so consumer-only reward recipients do not inflate totals.
func (s *MemoryStore) NetworkTotals(since time.Time) (store.NetworkTotalsRow, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t store.NetworkTotalsRow
	providers := make(map[string]struct{})
	for _, e := range s.history.ProviderEarnings {
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if e.AccountID != "" {
			providers[e.AccountID] = struct{}{}
		}
		if e.Model == "base_reward" {
			t.RewardEarningsMicroUSD += e.AmountMicroUSD
			continue
		}
		t.WorkEarningsMicroUSD += e.AmountMicroUSD
		t.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		t.Jobs++
	}
	for _, e := range s.history.LedgerEntries {
		if !store.IsRewardLedgerType(e.Type) {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if _, ok := providers[e.AccountID]; ok {
			t.RewardEarningsMicroUSD += e.AmountMicroUSD
		}
	}
	t.EarningsMicroUSD = t.WorkEarningsMicroUSD + t.RewardEarningsMicroUSD
	t.ActiveAccounts = int64(len(providers))
	return t, nil
}

// UsageLocationBuckets returns approximate request-origin aggregates (in-memory).
func (s *MemoryStore) UsageLocationBuckets(since time.Time) ([]store.UsageLocationBucket, error) {
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
	for _, r := range s.history.Usage {
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
	out := make([]store.UsageLocationBucket, 0, len(buckets))
	for _, b := range buckets {
		var lat, lng float64
		if b.coordCount > 0 {
			lat = b.latSum / float64(b.coordCount)
			lng = b.lngSum / float64(b.coordCount)
		}
		out = append(out, store.UsageLocationBucket{
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
	return out, nil
}

// UsageFlowBuckets aggregates directional consumer→provider flows in memory.
// providerLocs supplies live provider locations from the registry; the store's
// own providerRecords are used as a fallback for disconnected providers.
func (s *MemoryStore) UsageFlowBuckets(since time.Time, providerLocs map[string]*store.ProviderLocation) ([]store.UsageFlowBucket, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type flowKey struct {
		cCity, cRegion, cCountry string
		pCity, pRegion, pCountry string
	}
	type agg struct {
		b         store.UsageFlowBucket
		cLatSum   float64
		cLngSum   float64
		cCoordCnt int
		pLatSum   float64
		pLngSum   float64
		pCoordCnt int
	}

	// Resolve provider location: prefer live registry, fall back to stored records.
	resolveProviderLoc := func(providerID string) *store.ProviderLocation {
		if loc, ok := providerLocs[providerID]; ok && loc != nil {
			return loc
		}
		if rec, ok := s.providerRecords[providerID]; ok {
			return rec.Location
		}
		return nil
	}

	flows := make(map[flowKey]*agg)
	for _, r := range s.history.Usage {
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
			fa = &agg{b: store.UsageFlowBucket{
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

	out := make([]store.UsageFlowBucket, 0, len(flows))
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
	return out, nil
}
