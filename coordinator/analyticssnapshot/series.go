package analyticssnapshot

import (
	"errors"
	"math/big"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type Series struct {
	Start         time.Time           `json:"start_at"`
	End           time.Time           `json:"end_at"`
	BucketSeconds int64               `json:"bucket_seconds"`
	Buckets       []store.UsageBucket `json:"buckets"`
}

type SeriesSpec struct{ Lookback, Bucket time.Duration }

var SeriesSpecs = map[string]SeriesSpec{
	"30m": {30 * time.Minute, time.Minute}, "24h": {24 * time.Hour, 30 * time.Minute},
	"7d": {7 * 24 * time.Hour, 4 * time.Hour}, "30d": {30 * 24 * time.Hour, 12 * time.Hour},
}

func (s *Snapshot) validateSeries() error {
	if len(s.Series) != len(SeriesSpecs) {
		return errors.New("analytics snapshot has incomplete usage series")
	}
	for name, spec := range SeriesSpecs {
		series, ok := s.Series[name]
		end := s.AsOf.UTC().Truncate(spec.Bucket)
		if !ok || series.Buckets == nil || series.BucketSeconds != int64(spec.Bucket/time.Second) || !series.End.Equal(end) || !series.Start.Equal(end.Add(-spec.Lookback)) || len(series.Buckets) > int(spec.Lookback/spec.Bucket) {
			return errors.New("analytics usage series has invalid bounds")
		}
		previous := series.Start.Add(-spec.Bucket)
		for _, bucket := range series.Buckets {
			if bucket.Minute.Before(series.Start) || !bucket.Minute.Before(series.End) || !bucket.Minute.After(previous) || !bucket.Minute.Equal(bucket.Minute.UTC().Truncate(spec.Bucket)) || bucket.Requests < 0 {
				return errors.New("analytics usage series is unordered or invalid")
			}
			previous = bucket.Minute
		}
	}
	return s.validateSeriesOverlap()
}

// Sparse buckets mean zero. Compare every coarse interval fully represented
// by a finer series, including intervals omitted from the coarse result.
func (s *Snapshot) validateSeriesOverlap() error {
	names := []string{"30m", "24h", "7d", "30d"}
	for i, fineName := range names {
		fine := s.Series[fineName]
		fineStep := SeriesSpecs[fineName].Bucket
		fineBuckets := make(map[time.Time]store.UsageBucket, len(fine.Buckets))
		for _, bucket := range fine.Buckets {
			fineBuckets[bucket.Minute.UTC()] = bucket
		}
		for _, coarseName := range names[i+1:] {
			coarse := s.Series[coarseName]
			coarseStep := SeriesSpecs[coarseName].Bucket
			coarseBuckets := make(map[time.Time]store.UsageBucket, len(coarse.Buckets))
			for _, bucket := range coarse.Buckets {
				coarseBuckets[bucket.Minute.UTC()] = bucket
			}
			for start := coarse.Start.UTC(); start.Before(coarse.End); start = start.Add(coarseStep) {
				end := start.Add(coarseStep)
				if start.Before(fine.Start) || end.After(fine.End) {
					continue
				}
				var requests, prompt, completion big.Int
				for at := start; at.Before(end); at = at.Add(fineStep) {
					bucket := fineBuckets[at]
					requests.Add(&requests, big.NewInt(bucket.Requests))
					prompt.Add(&prompt, big.NewInt(bucket.PromptTokens))
					completion.Add(&completion, big.NewInt(bucket.CompletionTokens))
				}
				bucket := coarseBuckets[start]
				if requests.Cmp(big.NewInt(bucket.Requests)) != 0 ||
					prompt.Cmp(big.NewInt(bucket.PromptTokens)) != 0 ||
					completion.Cmp(big.NewInt(bucket.CompletionTokens)) != 0 {
					return errors.New("analytics usage series disagree across overlapping windows")
				}
			}
		}
	}
	return nil
}
