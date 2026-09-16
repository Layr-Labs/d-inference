package session

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// Telemetry delegates observations to their existing producers. It owns no
// counters or cached samples, and never changes routing or trust policy.
type Telemetry struct {
	Metrics   func() *metrics.Registry
	Incr      func(string, []string)
	Emit      func(context.Context, protocol.TelemetrySeverity, protocol.TelemetryKind, string, map[string]any)
	Heartbeat HeartbeatTelemetry
	Cache     CacheTelemetry
}

type HeartbeatTelemetry struct {
	BackendWedge  func(*protocol.BackendCapacity)
	MLXCache      func(*registry.Provider, *protocol.BackendCapacity, *protocol.BackendCapacity)
	PrefixCache   func(*registry.Provider, *protocol.BackendCapacity, *protocol.BackendCapacity)
	PagedStorage  func(*registry.Provider, *protocol.BackendCapacity, *protocol.BackendCapacity)
	ProcessMemory func(*registry.Provider, *protocol.BackendCapacity, *protocol.BackendCapacity)
}

type CacheTelemetry struct {
	Tier          func(string) string
	SSDLookup     func(string, string, float64)
	SSDDonation   func(string, float64, int)
	Receipt       func(string, registry.CacheReceiptResult)
	ModelReceipt  func(string, string, string, registry.CacheReceiptResult)
	ModelLookup   func(*protocol.PrefixCacheLookupV2Message, registry.CacheReceiptResult)
	ModelDonation func(*protocol.PrefixCacheReadyV2Message, registry.CacheReceiptResult)
}
