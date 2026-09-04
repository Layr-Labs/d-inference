package registry

import (
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// linkCounters are the per-connection provider WebSocket link counters. Every
// field is a monotonic count since the connection was accepted; the api layer
// diffs fleet-wide sums on its gauge cadence, so nothing here is ever reset.
//
// Inbound counters live on the Provider (the read loop records them); outbound
// counters live on the providerWriter (the single writer goroutine records
// them). Provider.LinkStats joins the two into one snapshot.
type linkCounters struct {
	framesIn          atomic.Uint64
	bytesIn           atomic.Uint64
	chunkFramesIn     atomic.Uint64
	chunkBytesIn      atomic.Uint64
	heartbeatFramesIn atomic.Uint64
	heartbeatBytesIn  atomic.Uint64

	dataFramesOut    atomic.Uint64
	dataBytesOut     atomic.Uint64
	controlFramesOut atomic.Uint64
	controlBytesOut  atomic.Uint64
	// fragmentedFramesOut counts data-lane messages that were written as
	// multiple WebSocket fragments (see providerWriteFragmentBytes).
	fragmentedFramesOut atomic.Uint64

	dataQueueFull    atomic.Uint64
	controlQueueFull atomic.Uint64
	writeTimeouts    atomic.Uint64
	// droppedOnClose counts fire-and-forget control frames (cancel,
	// trust_status, runtime_status) that were still queued when the writer
	// shut down. They had nowhere to go — the socket is dead — but they used
	// to vanish without a trace.
	droppedOnClose atomic.Uint64
	// controlFallbacks counts control frames that found the control lane full
	// and were delivered through the blocking fallback instead of being
	// dropped (see EnqueueControlOrWait).
	controlFallbacks atomic.Uint64

	// otherFramesIn/otherBytesIn are recorded explicitly rather than derived
	// as total−chunk−heartbeat: the totals and the per-kind counters are
	// separate atomics, so a tick can observe a frame in one and not the
	// other and an unsigned subtraction would wrap.
	otherFramesIn atomic.Uint64
	otherBytesIn  atomic.Uint64

	// finalOutbound is the writer's outbound counters frozen at
	// closeWriterNow, so totals survive the writer being detached. Guarded
	// by Provider.mu (written once, under p.mu, when the writer is dropped).
	finalOutbound *LinkStatsSnapshot

	// controlFallbacksInFlight bounds the goroutines parked in the blocking
	// control-lane fallback (EnqueueControlOrWait) per connection. Without a
	// bound, a provider that stops draining while emitting unique unknown
	// request IDs could park one goroutine per cancel for the fallback
	// timeout each.
	controlFallbacksInFlight atomic.Int32
}

// MaxControlFallbacksInFlight is the per-connection cap on concurrent
// blocking control-lane fallbacks (see EnqueueControlOrWait callers).
const MaxControlFallbacksInFlight = 8

// linkTotals are registry-wide accumulators for events that happen at
// connection teardown, after the connection has left the live map and can no
// longer be diffed per connection by the metrics emitter.
type linkTotals struct {
	droppedOnClose atomic.Uint64
	writeTimeouts  atomic.Uint64
}

// LinkTotalsSnapshot is a copy of the registry-wide teardown accumulators.
type LinkTotalsSnapshot struct {
	DroppedOnClose uint64
	WriteTimeouts  uint64
}

// LinkTotals returns the registry-wide teardown accumulators.
func (r *Registry) LinkTotals() LinkTotalsSnapshot {
	return LinkTotalsSnapshot{
		DroppedOnClose: r.linkTotals.droppedOnClose.Load(),
		WriteTimeouts:  r.linkTotals.writeTimeouts.Load(),
	}
}

// TryAcquireControlFallback reserves one of the per-connection blocking
// fallback slots; the caller must ReleaseControlFallback when done.
func (p *Provider) TryAcquireControlFallback() bool {
	if p == nil {
		return false
	}
	for {
		n := p.link.controlFallbacksInFlight.Load()
		if n >= MaxControlFallbacksInFlight {
			return false
		}
		if p.link.controlFallbacksInFlight.CompareAndSwap(n, n+1) {
			return true
		}
	}
}

// ReleaseControlFallback returns a slot taken by TryAcquireControlFallback.
func (p *Provider) ReleaseControlFallback() {
	if p == nil {
		return
	}
	p.link.controlFallbacksInFlight.Add(-1)
}

// LinkStatsSnapshot is a point-in-time copy of one provider connection's link
// counters plus the instantaneous writer queue depths.
type LinkStatsSnapshot struct {
	FramesIn          uint64
	BytesIn           uint64
	ChunkFramesIn     uint64
	ChunkBytesIn      uint64
	HeartbeatFramesIn uint64
	HeartbeatBytesIn  uint64
	OtherFramesIn     uint64
	OtherBytesIn      uint64

	DataFramesOut       uint64
	DataBytesOut        uint64
	ControlFramesOut    uint64
	ControlBytesOut     uint64
	FragmentedFramesOut uint64

	DataQueueFull    uint64
	ControlQueueFull uint64
	WriteTimeouts    uint64
	DroppedOnClose   uint64
	ControlFallbacks uint64

	// Instantaneous queue depths (not monotonic).
	DataQueueDepth    int
	ControlQueueDepth int
}

// FleetLinkStats aggregates LinkStatsSnapshot across every live provider
// connection. Counters are sums; depths are the fleet maximum plus the number
// of connections with a non-empty data lane, which is the "how many providers
// are backlogged right now" signal the sums cannot give.
type FleetLinkStats struct {
	Providers int
	Sum       LinkStatsSnapshot

	MaxDataQueueDepth    int
	MaxControlQueueDepth int
	BackloggedProviders  int
}

// RecordInboundFrame accounts one decoded provider frame of the given wire
// type. Called from the provider read loop after the frame type is known.
func (p *Provider) RecordInboundFrame(msgType string, size int) {
	if p == nil || size < 0 {
		return
	}
	n := uint64(size)
	p.link.framesIn.Add(1)
	p.link.bytesIn.Add(n)
	switch msgType {
	case protocol.TypeInferenceResponseChunk:
		p.link.chunkFramesIn.Add(1)
		p.link.chunkBytesIn.Add(n)
	case protocol.TypeHeartbeat:
		p.link.heartbeatFramesIn.Add(1)
		p.link.heartbeatBytesIn.Add(n)
	default:
		p.link.otherFramesIn.Add(1)
		p.link.otherBytesIn.Add(n)
	}
}

// LinkStats returns this connection's link counters. Safe to call from any
// goroutine; the writer pointer is read under p.mu, the counters are atomics.
func (p *Provider) LinkStats() LinkStatsSnapshot {
	if p == nil {
		return LinkStatsSnapshot{}
	}
	snap := LinkStatsSnapshot{
		FramesIn:          p.link.framesIn.Load(),
		BytesIn:           p.link.bytesIn.Load(),
		ChunkFramesIn:     p.link.chunkFramesIn.Load(),
		ChunkBytesIn:      p.link.chunkBytesIn.Load(),
		HeartbeatFramesIn: p.link.heartbeatFramesIn.Load(),
		HeartbeatBytesIn:  p.link.heartbeatBytesIn.Load(),
		OtherFramesIn:     p.link.otherFramesIn.Load(),
		OtherBytesIn:      p.link.otherBytesIn.Load(),
	}
	p.mu.Lock()
	w := p.writer
	final := p.link.finalOutbound
	p.mu.Unlock()
	if w != nil {
		w.fillLinkStats(&snap)
	} else if final != nil {
		snap.DataFramesOut = final.DataFramesOut
		snap.DataBytesOut = final.DataBytesOut
		snap.ControlFramesOut = final.ControlFramesOut
		snap.ControlBytesOut = final.ControlBytesOut
		snap.FragmentedFramesOut = final.FragmentedFramesOut
		snap.DataQueueFull = final.DataQueueFull
		snap.ControlQueueFull = final.ControlQueueFull
		snap.WriteTimeouts = final.WriteTimeouts
		snap.DroppedOnClose = final.DroppedOnClose
		snap.ControlFallbacks = final.ControlFallbacks
	}
	return snap
}

func (w *providerWriter) fillLinkStats(snap *LinkStatsSnapshot) {
	if w == nil || snap == nil {
		return
	}
	snap.DataFramesOut = w.link.dataFramesOut.Load()
	snap.DataBytesOut = w.link.dataBytesOut.Load()
	snap.ControlFramesOut = w.link.controlFramesOut.Load()
	snap.ControlBytesOut = w.link.controlBytesOut.Load()
	snap.FragmentedFramesOut = w.link.fragmentedFramesOut.Load()
	snap.DataQueueFull = w.link.dataQueueFull.Load()
	snap.ControlQueueFull = w.link.controlQueueFull.Load()
	snap.WriteTimeouts = w.link.writeTimeouts.Load()
	snap.DroppedOnClose = w.link.droppedOnClose.Load()
	snap.ControlFallbacks = w.link.controlFallbacks.Load()
	if w.queue != nil {
		snap.DataQueueDepth = len(w.queue)
	}
	if w.control != nil {
		snap.ControlQueueDepth = len(w.control)
	}
}

// LinkStatsByProvider returns a snapshot of every live connection's link
// counters keyed by provider (connection) ID.
func (r *Registry) LinkStatsByProvider() map[string]LinkStatsSnapshot {
	r.mu.RLock()
	providers := make(map[string]*Provider, len(r.providers))
	for id, p := range r.providers {
		providers[id] = p
	}
	r.mu.RUnlock()
	out := make(map[string]LinkStatsSnapshot, len(providers))
	for id, p := range providers {
		out[id] = p.LinkStats()
	}
	return out
}

// FleetLinkStats sums link counters across all live provider connections.
func (r *Registry) FleetLinkStats() FleetLinkStats {
	r.mu.RLock()
	providers := make([]*Provider, 0, len(r.providers))
	for _, p := range r.providers {
		providers = append(providers, p)
	}
	r.mu.RUnlock()

	var fleet FleetLinkStats
	for _, p := range providers {
		s := p.LinkStats()
		fleet.Providers++
		fleet.Sum.FramesIn += s.FramesIn
		fleet.Sum.BytesIn += s.BytesIn
		fleet.Sum.ChunkFramesIn += s.ChunkFramesIn
		fleet.Sum.ChunkBytesIn += s.ChunkBytesIn
		fleet.Sum.HeartbeatFramesIn += s.HeartbeatFramesIn
		fleet.Sum.HeartbeatBytesIn += s.HeartbeatBytesIn
		fleet.Sum.OtherFramesIn += s.OtherFramesIn
		fleet.Sum.OtherBytesIn += s.OtherBytesIn
		fleet.Sum.DataFramesOut += s.DataFramesOut
		fleet.Sum.DataBytesOut += s.DataBytesOut
		fleet.Sum.ControlFramesOut += s.ControlFramesOut
		fleet.Sum.ControlBytesOut += s.ControlBytesOut
		fleet.Sum.FragmentedFramesOut += s.FragmentedFramesOut
		fleet.Sum.DataQueueFull += s.DataQueueFull
		fleet.Sum.ControlQueueFull += s.ControlQueueFull
		fleet.Sum.WriteTimeouts += s.WriteTimeouts
		fleet.Sum.DroppedOnClose += s.DroppedOnClose
		fleet.Sum.ControlFallbacks += s.ControlFallbacks
		if s.DataQueueDepth > fleet.MaxDataQueueDepth {
			fleet.MaxDataQueueDepth = s.DataQueueDepth
		}
		if s.ControlQueueDepth > fleet.MaxControlQueueDepth {
			fleet.MaxControlQueueDepth = s.ControlQueueDepth
		}
		if s.DataQueueDepth > 0 {
			fleet.BackloggedProviders++
		}
	}
	return fleet
}
