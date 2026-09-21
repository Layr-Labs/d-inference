package store

import (
	"context"
	"sort"
	"time"
)

type modelDemandObservation struct {
	ReceivedAt       time.Time
	Scope            PublicDemandScope
	HTTPStatus       int
	Revision         int64
	EvidenceConflict bool
}

func (s *MemoryStore) projectModelDemandLocked(r RequestOutcomeRecord) {
	if r.PublicDemand == nil {
		return
	}
	if s.modelDemand == nil {
		s.modelDemand = make(map[string]modelDemandObservation)
	}
	d := *r.PublicDemand
	if r.EvidenceConflict {
		d.Outcome = "unknown"
	}
	if old, ok := s.modelDemand[r.CoordRequestID]; ok {
		if r.Revision < old.Revision {
			return
		}
		if old.EvidenceConflict {
			d.Outcome = "unknown"
			r.EvidenceConflict = true
		}
		d.Model = old.Scope.Model
		d.ConsumerHash = old.Scope.ConsumerHash
	}
	s.modelDemand[r.CoordRequestID] = modelDemandObservation{r.ReceivedAt, d, r.HTTPStatus, r.Revision, r.EvidenceConflict}
}

func (s *MemoryStore) ModelDemand(ctx context.Context, since, until time.Time) (ModelDemandSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return ModelDemandSnapshot{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	width := ModelDemandBucketSize(since, until)
	out := ModelDemandSnapshot{BucketSeconds: int64(width / time.Second), CollectionStartedAt: s.modelDemandStartedAt, Models: []ModelDemandCounts{}}
	counts := map[string]*ModelDemandCounts{}
	consumers := map[string]map[string]bool{}
	type seriesKey struct {
		model string
		index int
	}
	seriesCounts := map[seriesKey]*DemandOutcomeCounts{}
	seriesConsumers := map[seriesKey]map[string]bool{}
	for _, r := range s.modelDemand {
		if r.ReceivedAt.Before(since) || !r.ReceivedAt.Before(until) || r.Scope.Outcome == "excluded" {
			continue
		}
		m := r.Scope.Model
		if counts[m] == nil {
			counts[m] = &ModelDemandCounts{Model: m}
			consumers[m] = map[string]bool{}
		}
		counts[m].add(r.Scope.Outcome, r.HTTPStatus)
		consumers[m][r.Scope.ConsumerHash] = true
		key := seriesKey{m, int(r.ReceivedAt.Sub(since) / width)}
		if seriesCounts[key] == nil {
			seriesCounts[key] = &DemandOutcomeCounts{}
			seriesConsumers[key] = map[string]bool{}
		}
		seriesCounts[key].add(r.Scope.Outcome, r.HTTPStatus)
		seriesConsumers[key][r.Scope.ConsumerHash] = true
	}
	for m, c := range counts {
		if c.Requests >= ModelDemandMinRequests && len(consumers[m]) >= ModelDemandMinConsumers {
			c.TimeSeries = emptyModelDemandSeries(since, until, width)
			for i := range c.TimeSeries {
				key := seriesKey{m, i}
				counts := seriesCounts[key]
				if counts != nil && counts.Requests >= ModelDemandMinRequests && len(seriesConsumers[key]) >= ModelDemandMinConsumers {
					c.TimeSeries[i].Counts = counts
				}
			}
			out.Models = append(out.Models, *c)
		}
	}
	sort.Slice(out.Models, func(i, j int) bool {
		if out.Models[i].Requests != out.Models[j].Requests {
			return out.Models[i].Requests > out.Models[j].Requests
		}
		return out.Models[i].Model < out.Models[j].Model
	})
	return out, nil
}

func (s *MemoryStore) PruneModelDemand(ctx context.Context, before time.Time, _ int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for id, r := range s.modelDemand {
		if r.ReceivedAt.Before(before) {
			delete(s.modelDemand, id)
			n++
		}
	}
	return n, nil
}
