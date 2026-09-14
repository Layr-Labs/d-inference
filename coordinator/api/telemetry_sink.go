package api

import (
	"github.com/eigeninference/d-inference/coordinator/telemetry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/routequeue"
	"log/slog"
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

func crossesPowerOfTen(before, after int64) bool { return telemetry.CrossesPowerOfTen(before, after) }
