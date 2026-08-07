package api

import (
	"bytes"
	"fmt"
	"testing"
)

// TestWriteSSEFrame verifies the hot-path SSE writer produces output that is
// byte-identical to the fmt.Fprintf(w, "%s\n\n", frame) call sites it replaced.
// This is the regression guard for the perf change: it ensures dropping fmt's
// reflection-based formatting never silently alters the SSE wire framing.
func TestWriteSSEFrame(t *testing.T) {
	cases := []struct {
		name  string
		frame string
	}{
		{"chat_completion_chunk", `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"delta":{"content":"hi"}}]}`},
		{"done_sentinel", "data: [DONE]"},
		{"empty_frame", ""},
		{"unicode_payload", `data: {"content":"héllo 🌸"}`},
		{"percent_literal", `data: {"content":"100% done"}`}, // must NOT be treated as a format verb
		{"embedded_newline", "data: line1\nline2"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got bytes.Buffer
			writeSSEFrame(&got, tc.frame)

			// The exact expression the helper replaced at every call site.
			want := fmt.Sprintf("%s\n\n", tc.frame)
			if got.String() != want {
				t.Errorf("writeSSEFrame(%q) = %q, want %q", tc.frame, got.String(), want)
			}
		})
	}
}
