package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// linkMetricsEmitter turns the registry's monotonic per-connection link
// counters into DogStatsD counts + gauges on the gauge-loop cadence.
//
// Deltas are computed per provider connection (keyed by connection ID) rather
// than on the fleet sum: a provider that disconnects between two ticks takes
// its counters with it, which would make a fleet-sum delta go negative. A
// connection's increments between its last tick and its disconnect are lost —
// acceptable for rate dashboards, and strictly better than the previous state
// of the writer being entirely unmetered.
type linkMetricsEmitter struct {
	last       map[string]registry.LinkStatsSnapshot
	lastTotals registry.LinkTotalsSnapshot
}

func newLinkMetricsEmitter() *linkMetricsEmitter {
	return &linkMetricsEmitter{last: make(map[string]registry.LinkStatsSnapshot)}
}

// emit publishes one round of link metrics and remembers the snapshot for the
// next delta. Safe to call from a single goroutine only (the gauge loop).
func (e *linkMetricsEmitter) emit(s *Server) {
	if s == nil || s.registry == nil {
		return
	}
	byProvider := s.registry.LinkStatsByProvider()

	var (
		delta               registry.LinkStatsSnapshot
		maxDataDepth        int
		maxControlDepth     int
		backloggedProviders int
	)
	next := make(map[string]registry.LinkStatsSnapshot, len(byProvider))
	// inc adds cur-prev when the counter moved forward and nothing when it
	// did not: a connection torn down between the registry snapshot and its
	// counter read can report zeros, and an unsigned wraparound would
	// publish a 2^64-sized negative rate.
	inc := func(dst *uint64, cur, prev uint64) {
		if cur > prev {
			*dst += cur - prev
		}
	}
	for id, cur := range byProvider {
		next[id] = cur
		prev, seen := e.last[id]
		if !seen {
			prev = registry.LinkStatsSnapshot{}
		}
		inc(&delta.FramesIn, cur.FramesIn, prev.FramesIn)
		inc(&delta.BytesIn, cur.BytesIn, prev.BytesIn)
		inc(&delta.ChunkFramesIn, cur.ChunkFramesIn, prev.ChunkFramesIn)
		inc(&delta.ChunkBytesIn, cur.ChunkBytesIn, prev.ChunkBytesIn)
		inc(&delta.HeartbeatFramesIn, cur.HeartbeatFramesIn, prev.HeartbeatFramesIn)
		inc(&delta.HeartbeatBytesIn, cur.HeartbeatBytesIn, prev.HeartbeatBytesIn)
		inc(&delta.OtherFramesIn, cur.OtherFramesIn, prev.OtherFramesIn)
		inc(&delta.OtherBytesIn, cur.OtherBytesIn, prev.OtherBytesIn)
		inc(&delta.DataFramesOut, cur.DataFramesOut, prev.DataFramesOut)
		inc(&delta.DataBytesOut, cur.DataBytesOut, prev.DataBytesOut)
		inc(&delta.ControlFramesOut, cur.ControlFramesOut, prev.ControlFramesOut)
		inc(&delta.ControlBytesOut, cur.ControlBytesOut, prev.ControlBytesOut)
		inc(&delta.FragmentedFramesOut, cur.FragmentedFramesOut, prev.FragmentedFramesOut)
		inc(&delta.DataQueueFull, cur.DataQueueFull, prev.DataQueueFull)
		inc(&delta.ControlQueueFull, cur.ControlQueueFull, prev.ControlQueueFull)
		inc(&delta.ControlFallbacks, cur.ControlFallbacks, prev.ControlFallbacks)
		if cur.DataQueueDepth > maxDataDepth {
			maxDataDepth = cur.DataQueueDepth
		}
		if cur.ControlQueueDepth > maxControlDepth {
			maxControlDepth = cur.ControlQueueDepth
		}
		if cur.DataQueueDepth > 0 {
			backloggedProviders++
		}
	}
	e.last = next
	// Teardown-time events come from the registry-wide accumulators: a
	// dropped cancel or a write timeout on a connection that is already
	// gone would otherwise never be diffed.
	totals := s.registry.LinkTotals()
	var droppedOnClose, writeTimeouts uint64
	inc(&droppedOnClose, totals.DroppedOnClose, e.lastTotals.DroppedOnClose)
	inc(&writeTimeouts, totals.WriteTimeouts, e.lastTotals.WriteTimeouts)
	e.lastTotals = totals

	s.ddGauge("provider.ws.connections", float64(len(byProvider)), nil)
	s.ddGauge("provider.ws.data_queue_depth_max", float64(maxDataDepth), nil)
	s.ddGauge("provider.ws.control_queue_depth_max", float64(maxControlDepth), nil)
	s.ddGauge("provider.ws.backlogged_providers", float64(backloggedProviders), nil)

	s.ddCount("provider.ws.frames_in", int64(delta.ChunkFramesIn), []string{"kind:chunk"})
	s.ddCount("provider.ws.frames_in", int64(delta.HeartbeatFramesIn), []string{"kind:heartbeat"})
	s.ddCount("provider.ws.frames_in", int64(delta.OtherFramesIn), []string{"kind:other"})
	s.ddCount("provider.ws.bytes_in", int64(delta.ChunkBytesIn), []string{"kind:chunk"})
	s.ddCount("provider.ws.bytes_in", int64(delta.HeartbeatBytesIn), []string{"kind:heartbeat"})
	s.ddCount("provider.ws.bytes_in", int64(delta.OtherBytesIn), []string{"kind:other"})
	s.ddCount("provider.ws.frames_out", int64(delta.DataFramesOut), []string{"lane:data"})
	s.ddCount("provider.ws.frames_out", int64(delta.ControlFramesOut), []string{"lane:control"})
	s.ddCount("provider.ws.bytes_out", int64(delta.DataBytesOut), []string{"lane:data"})
	s.ddCount("provider.ws.bytes_out", int64(delta.ControlBytesOut), []string{"lane:control"})
	s.ddCount("provider.ws.fragmented_out", int64(delta.FragmentedFramesOut), nil)
	s.ddCount("provider.ws.queue_full", int64(delta.DataQueueFull), []string{"lane:data"})
	s.ddCount("provider.ws.queue_full", int64(delta.ControlQueueFull), []string{"lane:control"})
	s.ddCount("provider.ws.write_timeouts", int64(writeTimeouts), nil)
	s.ddCount("provider.ws.dropped_on_close", int64(droppedOnClose), nil)
	s.ddCount("provider.ws.control_fallbacks", int64(delta.ControlFallbacks), nil)
}
