package api

import (
	"sort"
	"strings"
)

// Bound both logical calls and active wire indices from untrusted providers.
// Existing calls can continue accumulating arguments after this limit.
const maxLogicalToolCalls = 128

type accumulatedToolCall struct {
	index     int
	id        string
	callType  string
	name      string
	arguments strings.Builder
}

// toolCallAccumulator reconstructs calls in arrival order. Wire indices need
// not be unique: a new non-empty ID at an occupied index starts a new call;
// id-less fragments continue the most recent call at that index. This retains
// compatibility with providers that reuse index zero for parallel calls.
type toolCallAccumulator struct {
	// Pointers keep non-empty strings.Builders stationary as the slice grows
	// and is sorted. Each argument fragment is appended without copying the
	// entire argument accumulated so far.
	calls         []*accumulatedToolCall
	activeByIndex map[int]int
	droppedDeltas int
}

func newToolCallAccumulator() *toolCallAccumulator {
	return &toolCallAccumulator{activeByIndex: make(map[int]int)}
}

func (a *toolCallAccumulator) apply(delta streamToolCallDelta) {
	pos, active := a.activeByIndex[delta.Index]
	if active && delta.ID != "" {
		if id := a.calls[pos].id; id != "" && id != delta.ID {
			active = false
		}
	}
	if !active {
		if len(a.calls) >= maxLogicalToolCalls {
			a.droppedDeltas++
			// Later id-less fragments of this dropped call must not be
			// appended to the preceding kept call at the same index.
			delete(a.activeByIndex, delta.Index)
			return
		}
		pos = len(a.calls)
		a.calls = append(a.calls, &accumulatedToolCall{index: delta.Index})
		a.activeByIndex[delta.Index] = pos
	}
	call := a.calls[pos]
	if delta.ID != "" {
		call.id = delta.ID
	}
	if delta.Type != "" {
		call.callType = delta.Type
	}
	if delta.Function.Name != "" {
		call.name = delta.Function.Name
	}
	call.arguments.WriteString(delta.Function.Arguments)
}

// finalize emits index-ordered calls, preserving arrival order for reused
// indices. Only this boundary builds the JSON objects; internal state stays
// typed and the wire index never enters the consumer response.
func (a *toolCallAccumulator) finalize() []map[string]any {
	if len(a.calls) == 0 {
		return nil
	}
	sort.SliceStable(a.calls, func(i, j int) bool {
		return a.calls[i].index < a.calls[j].index
	})
	out := make([]map[string]any, 0, len(a.calls))
	for _, call := range a.calls {
		function := map[string]any{"arguments": call.arguments.String()}
		if call.name != "" {
			function["name"] = call.name
		}
		entry := map[string]any{"function": function}
		if call.id != "" {
			entry["id"] = call.id
		}
		if call.callType != "" {
			entry["type"] = call.callType
		}
		out = append(out, entry)
	}
	return out
}
