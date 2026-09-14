package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/outcomequeue"
)

type requestOutcomeSink = outcomequeue.Sink

func newRequestOutcomeSink(s *Server, capacity int) *requestOutcomeSink {
	return outcomequeue.New(outcomequeue.Hooks{
		Logger: s.logger,
		Write: func(ctx context.Context, records []store.RequestOutcomeRecord) error {
			return s.store.RecordRequestOutcomes(ctx, records)
		},
		Incr:  s.ddIncr,
		Count: s.ddCount,
	}, capacity)
}
