package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestMeasuredThroughputLocked(t *testing.T) {
	slot := func(model string, decode, prefill float64) protocol.BackendSlotCapacity {
		return protocol.BackendSlotCapacity{Model: model, State: "running", ObservedDecodeTPS: decode, ObservedPrefillTPS: prefill}
	}
	cases := []struct {
		name string
		p    *Provider
		want MeasuredThroughput
	}{
		{
			name: "no heartbeat, no benchmark: unmeasured",
			p:    &Provider{},
			want: MeasuredThroughput{},
		},
		{
			name: "active model slot EWMA wins over a faster co-resident slot",
			p: &Provider{
				CurrentModel: "qwen-27b",
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("qwen-35b-a3b", 92.0, 3100),
					slot("qwen-27b", 31.5, 1400),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 31.5, PrefillTPS: 1400},
		},
		{
			name: "active model unmeasured: fall back to the best measured slot",
			p: &Provider{
				CurrentModel: "qwen-27b",
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("qwen-27b", 0, 0),
					slot("gemma-26b", 44.0, 900),
					slot("qwen-35b-a3b", 92.0, 3100),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 92.0, PrefillTPS: 3100},
		},
		{
			name: "axes resolve independently: active decode, other slot prefill",
			p: &Provider{
				CurrentModel: "qwen-27b",
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("qwen-27b", 31.5, 0),
					slot("gemma-26b", 44.0, 900),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 31.5, PrefillTPS: 900},
		},
		{
			name: "no active model: best measured slot",
			p: &Provider{
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("gemma-26b", 44.0, 900),
					slot("qwen-27b", 31.5, 1400),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 44.0, PrefillTPS: 1400},
		},
		{
			name: "slots present but all unmeasured: registration benchmark",
			p: &Provider{
				DecodeTPS:    60,
				PrefillTPS:   700,
				CurrentModel: "qwen-27b",
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("qwen-27b", 0, 0),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 60, PrefillTPS: 700},
		},
		{
			name: "legacy provider without backend capacity: registration benchmark",
			p:    &Provider{DecodeTPS: 60, PrefillTPS: 700},
			want: MeasuredThroughput{DecodeTPS: 60, PrefillTPS: 700},
		},
		{
			name: "heartbeat EWMA beats a stale registration benchmark",
			p: &Provider{
				DecodeTPS:    60,
				CurrentModel: "qwen-27b",
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
					slot("qwen-27b", 31.5, 0),
				}},
			},
			want: MeasuredThroughput{DecodeTPS: 31.5},
		},
		{
			name: "memory bandwidth alone is never reported as a measurement",
			p:    &Provider{Hardware: protocol.Hardware{MemoryBandwidthGBs: 400}},
			want: MeasuredThroughput{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.p.mu.Lock()
			got := tc.p.MeasuredThroughputLocked()
			tc.p.mu.Unlock()
			if got != tc.want {
				t.Fatalf("MeasuredThroughputLocked() = %+v, want %+v", got, tc.want)
			}
		})
	}
}
