package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func orFrame(delta, finish string) string {
	return `data: {"id":"fixture-response","object":"chat.completion.chunk","created":1700000000,"model":"conformance-alias","choices":[{"index":0,"delta":` + delta + `,"finish_reason":` + finish + `}]}` + "\n\n"
}
func orResponse(body io.ReadCloser) *http.Response {
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/event-stream"}}, Body: body}
}

type orByteReader struct{ r io.Reader }

func (r orByteReader) Read(b []byte) (int, error) { return r.r.Read(b[:min(1, len(b))]) }

type orBrokenReader struct{}

func (orBrokenReader) Read([]byte) (int, error) { return 0, errors.New("injected read failure") }

func TestOpenRouterConformanceObserver(t *testing.T) {
	content := orFrame(`{"content":"héllo"}`, "null")
	finish := orFrame(`{}`, `"stop"`)
	done := "data: [DONE]\n\n"
	usage := `data: {"id":"fixture-response","object":"chat.completion.chunk","created":1700000000,"model":"conformance-alias","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20}}` + "\n\n"
	for _, tc := range []struct {
		name, body string
		fail       bool
	}{
		{"coalesced", content + finish + usage + done, false},
		{"optional_usage", content + finish + done, false},
		{"crlf", strings.ReplaceAll(content+finish+done, "\n", "\r\n"), false},
		{"multiline", strings.Replace(content, `,"object"`, ",\ndata: \"object\"", 1) + finish + done, false},
		{"missing_done", content + finish, true},
		{"duplicate_done", content + finish + done + done, true},
		{"trailing_content", content + finish + done + content, true},
		{"invalid_json", "data: {oops}\n\n", true},
		{"truncated_json", "data: {\n\n", true},
		{"truncated_event", strings.TrimSuffix(content, "\n\n"), true},
		{"in_band_200", content + "data: {\"error\":{\"message\":\"fixture error\"}}\n\n" + done, true},
		{"usage_only", usage + done, true},
		{"role_only", orFrame(`{"role":"assistant"}`, "null") + finish + done, true},
		{"missing_finish", content + done, true},
		{"identity_change", content + strings.Replace(finish, "fixture-response", "wrong", 1) + done, true},
		{"semantic_after_finish", content + finish + content + done, true},
		{"invalid_utf8", strings.Replace(content, "héllo", string([]byte{0xff}), 1) + finish + done, true},
		{"oversize_event", "data: " + strings.Repeat("x", orMaxEvent) + "\n\n", true},
		{"body_bound", strings.Repeat(": "+strings.Repeat("x", 4000)+"\n\n", 80), true},
		{"invalid_field", "garbage\n\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			o, err := orObserve(ctx, orResponse(io.NopCloser(strings.NewReader(tc.body))), time.Now(), nil)
			if (err != nil) != tc.fail {
				t.Fatalf("failure=%v want %v; observation=%+v", err, tc.fail, o)
			}
			if !tc.fail && (o.Text != "héllo" || o.SemanticNS == nil || o.Done != 1) {
				t.Fatalf("invalid success: %+v", o)
			}
			if (tc.name == "usage_only" || tc.name == "role_only") && o.SemanticNS != nil {
				t.Fatal("nonsemantic event acquired TTFT")
			}
		})
	}
	t.Run("split_utf8_and_events", func(t *testing.T) {
		o, err := orObserve(context.Background(), orResponse(io.NopCloser(orByteReader{strings.NewReader(content + finish + done)})), time.Now(), nil)
		if err != nil || o.Text != "héllo" {
			t.Fatalf("split: %+v %v", o, err)
		}
	})
	t.Run("read_error_after_done", func(t *testing.T) {
		_, err := orObserve(context.Background(), orResponse(io.NopCloser(io.MultiReader(strings.NewReader(content+finish+done), orBrokenReader{}))), time.Now(), nil)
		if err == nil {
			t.Fatal("read error hidden")
		}
	})
	t.Run("role_then_delayed_semantics", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		gate := &orReadGate{head: strings.NewReader(orFrame(`{"role":"assistant"}`, "null")), tail: strings.NewReader(content + finish + done), ctx: ctx, next: make(chan struct{}), release: make(chan struct{})}
		start := time.Now()
		result := make(chan orObservation, 1)
		errs := make(chan error, 1)
		go func() { o, e := orObserve(ctx, orResponse(io.NopCloser(gate)), start, nil); result <- o; errs <- e }()
		select {
		case <-gate.next:
		case <-ctx.Done():
			t.Fatal("observer did not request bytes after parsing role")
		}
		release := time.Now()
		close(gate.release)
		o := <-result
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
		if o.FirstEventNS == nil || o.SemanticNS == nil || *o.FirstEventNS > release.Sub(start).Nanoseconds() || *o.SemanticNS < release.Sub(start).Nanoseconds() {
			t.Fatalf("timing conflated: %+v", o)
		}
	})
	t.Run("bounded_blocked_body", func(t *testing.T) {
		r, w := io.Pipe()
		defer w.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		defer cancel()
		if _, err := orObserve(ctx, orResponse(r), time.Now(), nil); err == nil {
			t.Fatal("blocked stream passed")
		}
	})
	for _, delta := range []string{`{"reasoning":"thought"}`, `{"reasoning_content":"thought"}`, `{"refusal":"no"}`, `{"tool_calls":[{"function":{"name":"fixture_tool","arguments":"{}"}}]}`} {
		t.Run("semantic_kind", func(t *testing.T) {
			o, err := orObserve(context.Background(), orResponse(io.NopCloser(strings.NewReader(orFrame(delta, "null")+finish+done))), time.Now(), nil)
			if err != nil || o.SemanticNS == nil {
				t.Fatalf("semantic kind: %v", err)
			}
		})
	}
}

// bufio must exhaust and parse the complete role frame before requesting this
// reader's tail. This makes the test's release point a parser barrier.
type orReadGate struct {
	head, tail    *strings.Reader
	ctx           context.Context
	next, release chan struct{}
	once          sync.Once
}

func (r *orReadGate) Read(b []byte) (int, error) {
	if r.head.Len() > 0 {
		return r.head.Read(b)
	}
	r.once.Do(func() { close(r.next) })
	select {
	case <-r.release:
		return r.tail.Read(b)
	case <-r.ctx.Done():
		return 0, r.ctx.Err()
	}
}
