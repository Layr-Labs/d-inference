package registry

import (
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestHeartbeatStatsMergePreservesWireCounterSemantics(t *testing.T) {
	wire := reflect.TypeOf(protocol.HeartbeatStats{})
	for field := 0; field < wire.NumField(); field++ {
		t.Run(wire.Field(field).Name, func(t *testing.T) {
			for _, sample := range []struct{ current, delta int64 }{{-1, 0}, {0, 0}, {3, 3}, {5, 0}, {9, 4}} {
				var previous, current, total protocol.HeartbeatStats
				reflect.ValueOf(&previous).Elem().Field(field).SetInt(5)
				reflect.ValueOf(&current).Elem().Field(field).SetInt(sample.current)
				reflect.ValueOf(&total).Elem().Field(field).SetInt(100)
				applyHeartbeatStatsDelta(&total, previous, current)
				if got := reflect.ValueOf(total).Field(field).Int(); got != 100+sample.delta {
					t.Fatalf("sample %d: lifetime counter = %d, want %d", sample.current, got, 100+sample.delta)
				}
				merged := mergeHeartbeatSessionStats(previous, current)
				want := sample.current
				// Optional additive counters retain the previous reading when a
				// legacy heartbeat omits them. Required primary counters reset.
				if want == 0 && strings.Contains(wire.Field(field).Tag.Get("json"), ",omitempty") {
					want = 5
				}
				if got := reflect.ValueOf(merged).Field(field).Int(); got != want {
					t.Fatalf("sample %d: retained session counter = %d, want %d", sample.current, got, want)
				}
			}
		})
	}
}
