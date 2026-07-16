package api

import (
	"fmt"
	"math"
	"testing"
)

// T11/T10 (PR #548 review): chunks come from providers, which are only
// semi-trusted — a buggy or malicious provider can stream an unbounded
// number of distinct-id tool-call deltas into the non-streaming
// reconstruction. extractMessage caps LOGICAL tool calls at
// maxLogicalToolCalls: past the cap, deltas that would start a new logical
// call are dropped (counted + logged), while argument fragments for
// already-kept calls keep accumulating — kept calls are never truncated or
// corrupted, and huge/sparse wire indices cannot grow the tracking map past
// the cap either.

// capCallID builds the distinct id for the i-th flood call.
func capCallID(i int) string { return fmt.Sprintf("c%d", i) }

// A malicious all-index-0 stream of cap+1 distinct-id calls keeps exactly
// the first maxLogicalToolCalls calls, in arrival order, and drops the rest.
func TestExtractMessageCapsLogicalToolCalls(t *testing.T) {
	var chunks []string
	for i := 1; i <= maxLogicalToolCalls+1; i++ {
		chunks = append(chunks, tcDelta(0, capCallID(i), "fn", fmt.Sprintf(`{"n":%d}`, i)))
	}

	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != maxLogicalToolCalls {
		t.Fatalf("tool_calls length = %d, want cap %d", len(msg.ToolCalls), maxLogicalToolCalls)
	}
	for i, tc := range msg.ToolCalls {
		if wantID := capCallID(i + 1); tc["id"] != wantID {
			t.Fatalf("call %d id = %v, want %s (arrival order must be stable under the cap)", i, tc["id"], wantID)
		}
	}
	last := msg.ToolCalls[maxLogicalToolCalls-1]
	fn := last["function"].(map[string]any)
	if want := fmt.Sprintf(`{"n":%d}`, maxLogicalToolCalls); fn["arguments"] != want {
		t.Errorf("last kept call arguments = %q, want %q (dropped call must not contaminate it)", fn["arguments"], want)
	}
}

// Past the cap, kept calls still accumulate their own argument fragments,
// and fragments belonging to a dropped call are swallowed — never merged
// onto a kept call at the same wire index.
func TestExtractMessageAtCapKeepsAccumulatingKeptCalls(t *testing.T) {
	chunks := []string{
		// A long-running kept call on its own wire index.
		tcDelta(5, "keeper", "keep_fn", `{"k":`),
	}
	// Fill the remaining cap slots with distinct-id calls at index 0.
	for i := 1; i <= maxLogicalToolCalls-1; i++ {
		chunks = append(chunks, tcDelta(0, capCallID(i), "fn", fmt.Sprintf(`{"n":%d}`, i)))
	}
	chunks = append(chunks,
		// Cap is full: this new logical call must be dropped...
		tcDelta(0, "overflow", "fn", `{"evil":true}`),
		// ...and its id-less fragments swallowed, not merged onto the
		// last kept index-0 call.
		tcDelta(0, "", "", `LEAK`),
		// The kept call keeps accumulating fragments as usual.
		tcDelta(5, "", "", `1}`),
	)

	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != maxLogicalToolCalls {
		t.Fatalf("tool_calls length = %d, want cap %d", len(msg.ToolCalls), maxLogicalToolCalls)
	}
	// Output is index-ordered: the index-0 group first, keeper (index 5) last.
	keeper := msg.ToolCalls[maxLogicalToolCalls-1]
	if keeper["id"] != "keeper" {
		t.Fatalf("last call id = %v, want keeper (index 5 sorts after index 0)", keeper["id"])
	}
	keeperFn := keeper["function"].(map[string]any)
	if keeperFn["arguments"] != `{"k":1}` {
		t.Errorf("keeper arguments = %q, want %q (kept calls must keep accumulating past the cap)", keeperFn["arguments"], `{"k":1}`)
	}
	lastKept := msg.ToolCalls[maxLogicalToolCalls-2]
	if wantID := capCallID(maxLogicalToolCalls - 1); lastKept["id"] != wantID {
		t.Fatalf("last index-0 call id = %v, want %s", lastKept["id"], wantID)
	}
	lastKeptFn := lastKept["function"].(map[string]any)
	if want := fmt.Sprintf(`{"n":%d}`, maxLogicalToolCalls-1); lastKeptFn["arguments"] != want {
		t.Errorf("last kept index-0 arguments = %q, want %q (dropped call's fragments must be swallowed, not merged)", lastKeptFn["arguments"], want)
	}
	for _, tc := range msg.ToolCalls {
		if tc["id"] == "overflow" {
			t.Errorf("dropped call id overflow must not appear in output: %v", tc)
		}
	}
}

// Huge and sparse wire indices are fine for Go maps (no preallocation by
// key value), but each distinct index could otherwise add a tracking entry
// forever; the logical-call cap bounds that too.
func TestExtractMessageCapBoundsSparseHugeIndices(t *testing.T) {
	var chunks []string
	for i := 1; i <= maxLogicalToolCalls+10; i++ {
		// Distinct sparse indices, including very large ones.
		chunks = append(chunks, tcDelta(i*1000003, capCallID(i), "fn", `{}`))
	}
	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != maxLogicalToolCalls {
		t.Fatalf("tool_calls length = %d, want cap %d", len(msg.ToolCalls), maxLogicalToolCalls)
	}
}

// T5 (PR #548 review): the sort comparator must never panic on a corrupt
// "index" value. Entries are always built with an int index, so this is
// unreachable from extractMessage input — the helper is pinned directly.
func TestToolCallWireIndexCorruptValue(t *testing.T) {
	if got := toolCallWireIndex(map[string]any{"index": 3}); got != 3 {
		t.Errorf("int index = %d, want 3", got)
	}
	if got := toolCallWireIndex(map[string]any{"index": "corrupt"}); got != math.MaxInt {
		t.Errorf("corrupt index = %d, want math.MaxInt (sorts last, no panic)", got)
	}
	if got := toolCallWireIndex(map[string]any{}); got != math.MaxInt {
		t.Errorf("missing index = %d, want math.MaxInt (sorts last, no panic)", got)
	}
}

// A hand-built entry with a corrupt "index" (unreachable through
// extractMessage, which always stores int) must not panic finalize; it
// sorts last, after all valid indices.
func TestToolCallFinalizeCorruptIndexNoPanic(t *testing.T) {
	acc := newToolCallAccumulator()
	acc.calls = []map[string]any{
		{"index": "corrupt", "id": "bad", "function": map[string]any{"arguments": ""}},
		{"index": 1, "id": "good_b", "function": map[string]any{"arguments": ""}},
		{"index": 0, "id": "good_a", "function": map[string]any{"arguments": ""}},
	}
	out := acc.finalize()
	if len(out) != 3 {
		t.Fatalf("finalize length = %d, want 3", len(out))
	}
	if out[0]["id"] != "good_a" || out[1]["id"] != "good_b" || out[2]["id"] != "bad" {
		t.Fatalf("want valid entries index-ordered with corrupt entry last, got %v / %v / %v", out[0]["id"], out[1]["id"], out[2]["id"])
	}
}

// A hand-built entry whose "function" or "arguments" value was corrupted
// (also unreachable through extractMessage) must not panic apply; the
// corrupt value is replaced and accumulation continues.
func TestToolCallApplyCorruptFunctionNoPanic(t *testing.T) {
	acc := newToolCallAccumulator()
	acc.calls = []map[string]any{
		{"index": 0, "id": "call_a", "function": "corrupt"},
		{"index": 1, "id": "call_b", "function": map[string]any{"arguments": 42}},
	}
	acc.activeByIndex = map[int]int{0: 0, 1: 1}

	var frag streamedToolCallDelta
	frag.Index = 0
	frag.Function.Arguments = `{"x":1}`
	acc.apply(frag)
	frag.Index = 1
	acc.apply(frag)

	fn0 := acc.calls[0]["function"].(map[string]any)
	if fn0["arguments"] != `{"x":1}` {
		t.Errorf("corrupt function map: arguments = %q, want %q", fn0["arguments"], `{"x":1}`)
	}
	fn1 := acc.calls[1]["function"].(map[string]any)
	if fn1["arguments"] != `{"x":1}` {
		t.Errorf("corrupt arguments value: arguments = %q, want %q", fn1["arguments"], `{"x":1}`)
	}
}
