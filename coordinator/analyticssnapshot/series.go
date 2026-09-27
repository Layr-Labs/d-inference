package analyticssnapshot

import (
	"errors"
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
			if bucket.Minute.Before(series.Start) || !bucket.Minute.Before(series.End) || !bucket.Minute.After(previous) || !bucket.Minute.Equal(bucket.Minute.UTC().Truncate(spec.Bucket)) || bucket.Requests < 0 || bucket.PromptTokens < 0 || bucket.CompletionTokens < 0 {
				return errors.New("analytics usage series is unordered or invalid")
			}
			previous = bucket.Minute
		}
	}
	return nil
}
