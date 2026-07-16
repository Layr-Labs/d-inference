package api

import "testing"

// E6 (2026-07-15 platform errors deep dive): the engine emits EVERY streamed
// parallel tool call with `index: 0`, and extractMessage keyed reconstruction
// by index — so a second call overwrote the first's id/name and concatenated
// both argument streams into one corrupted call. Defensively, a delta whose
// non-empty id DIFFERS from the current entry's non-empty id starts a NEW
// logical call (arrival order preserved); well-behaved indexed streams keep
// index-keyed accumulation. (The engine-side proper fix — unique indices in
// MLXOpenAIService — lives in the submodule and ships separately.)

func tcDelta(index int, id, name, args string) string {
	chunk := `data: {"choices":[{"delta":{"tool_calls":[{"index":` + itoa(index)
	if id != "" {
		chunk += `,"id":"` + id + `"`
	}
	chunk += `,"function":{`
	sep := ""
	if name != "" {
		chunk += `"name":"` + name + `"`
		sep = ","
	}
	chunk += sep + `"arguments":` + quoteJSON(args) + `}}]}}]}`
	return chunk
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

func quoteJSON(s string) string {
	out := `"`
	for _, r := range s {
		switch r {
		case '"':
			out += `\"`
		case '\\':
			out += `\\`
		default:
			out += string(r)
		}
	}
	return out + `"`
}

// Two parallel calls both streamed at index 0 with distinct ids: the second
// id must START A NEW logical call — two calls out, each with its own
// id/name/arguments — instead of one merged call with concatenated args.
func TestExtractMessageTwoIndexZeroCallsWithDistinctIDs(t *testing.T) {
	chunks := []string{
		tcDelta(0, "call_a", "get_weather", ""),
		tcDelta(0, "", "", `{"city":`),
		tcDelta(0, "", "", `"SF"}`),
		tcDelta(0, "call_b", "get_time", ""),
		tcDelta(0, "", "", `{"tz":"PST"}`),
	}

	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != 2 {
		t.Fatalf("tool_calls length = %d, want 2 (second index-0 id must not merge into the first call): %v", len(msg.ToolCalls), msg.ToolCalls)
	}
	first, second := msg.ToolCalls[0], msg.ToolCalls[1]
	if first["id"] != "call_a" || second["id"] != "call_b" {
		t.Fatalf("ids = %v, %v; want call_a then call_b (arrival order)", first["id"], second["id"])
	}
	fn1 := first["function"].(map[string]any)
	fn2 := second["function"].(map[string]any)
	if fn1["name"] != "get_weather" || fn2["name"] != "get_time" {
		t.Errorf("names = %v, %v; want get_weather / get_time", fn1["name"], fn2["name"])
	}
	if fn1["arguments"] != `{"city":"SF"}` {
		t.Errorf("first arguments = %q, want %q", fn1["arguments"], `{"city":"SF"}`)
	}
	if fn2["arguments"] != `{"tz":"PST"}` {
		t.Errorf("second arguments = %q, want %q (must not contain the first call's fragments)", fn2["arguments"], `{"tz":"PST"}`)
	}
}

// The id being RE-SENT on later deltas of the same call (some engines repeat
// it on every frame) is a continuation, never a split.
func TestExtractMessageRepeatedSameIDDoesNotSplit(t *testing.T) {
	chunks := []string{
		tcDelta(0, "call_a", "run", ""),
		tcDelta(0, "call_a", "", `{"a":`),
		tcDelta(0, "call_a", "", `1}`),
	}
	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != 1 {
		t.Fatalf("tool_calls length = %d, want 1", len(msg.ToolCalls))
	}
	fn := msg.ToolCalls[0]["function"].(map[string]any)
	if fn["arguments"] != `{"a":1}` {
		t.Errorf("arguments = %q, want %q", fn["arguments"], `{"a":1}`)
	}
}

// Well-behaved indexed streams (unique index per call, interleaved deltas)
// keep index-keyed accumulation and index-ordered output.
func TestExtractMessageWellBehavedIndexedStreamUnchanged(t *testing.T) {
	chunks := []string{
		tcDelta(1, "call_b", "second", ""),
		tcDelta(0, "call_a", "first", ""),
		tcDelta(0, "", "", `{"x":1}`),
		tcDelta(1, "", "", `{"y":2}`),
	}
	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != 2 {
		t.Fatalf("tool_calls length = %d, want 2", len(msg.ToolCalls))
	}
	if msg.ToolCalls[0]["id"] != "call_a" || msg.ToolCalls[1]["id"] != "call_b" {
		t.Fatalf("output must be index-ordered: got %v, %v", msg.ToolCalls[0]["id"], msg.ToolCalls[1]["id"])
	}
	fn1 := msg.ToolCalls[0]["function"].(map[string]any)
	fn2 := msg.ToolCalls[1]["function"].(map[string]any)
	if fn1["arguments"] != `{"x":1}` || fn2["arguments"] != `{"y":2}` {
		t.Errorf("arguments = %q / %q, want index-keyed accumulation", fn1["arguments"], fn2["arguments"])
	}
}

// Sparse wire indices (0 and 2) must both survive — the old dense 0..n-1 map
// walk silently dropped the call at index 2.
func TestExtractMessageSparseIndicesNotDropped(t *testing.T) {
	chunks := []string{
		tcDelta(0, "call_a", "first", `{}`),
		tcDelta(2, "call_c", "third", `{}`),
	}
	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != 2 {
		t.Fatalf("tool_calls length = %d, want 2 (sparse index dropped)", len(msg.ToolCalls))
	}
	if msg.ToolCalls[1]["id"] != "call_c" {
		t.Errorf("second call id = %v, want call_c", msg.ToolCalls[1]["id"])
	}
}

// Three calls all at index 0: arrival order is preserved across every split.
func TestExtractMessageThreeIndexZeroCalls(t *testing.T) {
	chunks := []string{
		tcDelta(0, "c1", "f1", `{"n":1}`),
		tcDelta(0, "c2", "f2", `{"n":2}`),
		tcDelta(0, "c3", "f3", `{"n":3}`),
	}
	msg := extractMessage(chunks)
	if len(msg.ToolCalls) != 3 {
		t.Fatalf("tool_calls length = %d, want 3", len(msg.ToolCalls))
	}
	for i, wantID := range []string{"c1", "c2", "c3"} {
		if msg.ToolCalls[i]["id"] != wantID {
			t.Errorf("call %d id = %v, want %s", i, msg.ToolCalls[i]["id"], wantID)
		}
	}
}
