package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/telemetry/routequeue"
)

type telemetrySink = routequeue.Sink

const (
	defaultTelemetrySinkCapacity = routequeue.DefaultCapacity
	defaultTelemetrySinkWorkers  = 1
	telemetrySinkShutdownFlush   = routequeue.ShutdownFlush
)

func newTelemetrySink(logger *slog.Logger, capacity, workers int) *telemetrySink {
	return routequeue.New(logger, capacity, workers)
}
