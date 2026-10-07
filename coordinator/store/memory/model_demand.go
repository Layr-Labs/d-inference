package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type modelDemandObservation struct {
	ReceivedAt       time.Time
	Scope            store.PublicDemandScope
	HTTPStatus       int
	Revision         int64
	EvidenceConflict bool
}

func (s *MemoryStore) projectModelDemandLocked(r store.RequestOutcomeRecord) {
	if r.PublicDemand == nil {
		return
	}
	if s.modelDemand == nil {
		s.modelDemand = make(map[string]modelDemandObservation)
	}
	d := *r.PublicDemand
	if old, ok := s.modelDemand[r.CoordRequestID]; ok {
		conflict := old.EvidenceConflict || r.EvidenceConflict ||
			!old.ReceivedAt.Equal(r.ReceivedAt) || old.Scope.Model != d.Model || old.Scope.ConsumerHash != d.ConsumerHash ||
			(old.Revision == r.Revision && (old.Scope.Outcome != d.Outcome || old.HTTPStatus != r.HTTPStatus))
		if r.Revision <= old.Revision {
			if conflict {
				old.Scope.Outcome = "unknown"
				old.EvidenceConflict = true
				s.modelDemand[r.CoordRequestID] = old
			}
			return
		}
		r.ReceivedAt = old.ReceivedAt
		r.EvidenceConflict = conflict
		d.Model = old.Scope.Model
		d.ConsumerHash = old.Scope.ConsumerHash
	}
	if r.EvidenceConflict {
		d.Outcome = "unknown"
	}
	s.modelDemand[r.CoordRequestID] = modelDemandObservation{r.ReceivedAt, d, r.HTTPStatus, r.Revision, r.EvidenceConflict}
}

func (s *MemoryStore) ModelDemand(ctx context.Context, since, until time.Time) (store.ModelDemandSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return store.ModelDemandSnapshot{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	width := store.ModelDemandBucketSize(since, until)
	out := store.ModelDemandSnapshot{BucketSeconds: int64(width / time.Second), CollectionStartedAt: s.modelDemandStartedAt, Models: []store.ModelDemandCounts{}}
	type hourKey struct {
		model string
		at    time.Time
	}
	type hourCounts struct {
		store.DemandOutcomeCounts
		consumers map[string]struct{}
	}
	hours := map[hourKey]*hourCounts{}
	for _, r := range s.modelDemand {
		if r.ReceivedAt.Before(since) || !r.ReceivedAt.Before(until) || r.Scope.Outcome == "excluded" {
			continue
		}
		key := hourKey{r.Scope.Model, r.ReceivedAt.UTC().Truncate(time.Hour)}
		c := hours[key]
		if c == nil {
			c = &hourCounts{consumers: make(map[string]struct{}, store.ModelDemandMinConsumers)}
			hours[key] = c
		}
		c.Add(r.Scope.Outcome, r.HTTPStatus)
		if len(c.consumers) < store.ModelDemandMinConsumers {
			c.consumers[r.Scope.ConsumerHash] = struct{}{}
		}
	}
	byModel := map[string]int{}
	for key, c := range hours {
		if c.Requests < store.ModelDemandMinRequests || len(c.consumers) < store.ModelDemandMinConsumers {
			continue
		}
		i, ok := byModel[key.model]
		if !ok {
			i = len(out.Models)
			byModel[key.model] = i
			out.Models = append(out.Models, store.ModelDemandCounts{Model: key.model, TimeSeries: shared.EmptyModelDemandSeries(since, until, width)})
		}
		bucket := &out.Models[i].TimeSeries[int(key.at.Sub(since)/width)]
		if bucket.Counts == nil {
			bucket.Counts = &store.DemandOutcomeCounts{}
		}
		bucket.Counts.Merge(&c.DemandOutcomeCounts)
	}
	shared.SummarizeModelDemand(&out)
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
