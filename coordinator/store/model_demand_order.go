package store

import (
	"cmp"
	"slices"
	"time"
)

// Keep snapshots of each request in caller order (first receipt/endpoint wins),
// but order independent requests by their aggregate lock key. Never sort a
// conflicting revision ahead of its original observation.
func orderModelDemandWrites(records []RequestOutcomeRecord) []RequestOutcomeRecord {
	type key struct {
		hour            time.Time
		model, consumer string
	}
	keys := make(map[string]key, len(records))
	for _, r := range records {
		k, exists := keys[r.CoordRequestID]
		if !exists {
			k.hour = r.ReceivedAt.UTC().Truncate(time.Hour)
		}
		if k.model == "" && r.PublicDemand != nil {
			k.model = r.PublicDemand.Model
			k.consumer = r.PublicDemand.ConsumerHash
		}
		keys[r.CoordRequestID] = k
	}
	out := slices.Clone(records)
	slices.SortStableFunc(out, func(a, b RequestOutcomeRecord) int {
		if a.CoordRequestID == b.CoordRequestID {
			return 0
		}
		ak, bk := keys[a.CoordRequestID], keys[b.CoordRequestID]
		if n := ak.hour.Compare(bk.hour); n != 0 {
			return n
		}
		if n := cmp.Compare(ak.model, bk.model); n != 0 {
			return n
		}
		if n := cmp.Compare(ak.consumer, bk.consumer); n != 0 {
			return n
		}
		return cmp.Compare(a.CoordRequestID, b.CoordRequestID)
	})
	return out
}
