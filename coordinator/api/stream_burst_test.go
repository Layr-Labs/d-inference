package api

// Streaming-relay burst tests (real HTTP + fake WebSocket provider). The relay
// coalesces chunks that are already queued when it wakes; these tests pin the
// consumer-visible byte stream so coalescing can never reorder, drop,
// duplicate, or reframe a chunk, and pin the terminal semantics (held
// finish/usage frames, single [DONE], in-band provider error, cancel on client
// disconnect) across all three streaming variants.

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const burstChatRequest = `{"model":"` + burstTestModel + `","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":1000}`

// chatBurstGolden is the exact SSE byte stream the pre-coalescing relay
// produced for burstChatChunks(50) followed by inference_complete with
// prompt=10 / completion=50 / reasoning=7. Captured from the baseline code
// path (commit 37d0f181c) and pinned verbatim: any change to per-chunk
// transforms, ordering, framing, or terminal events must update this golden
// deliberately.
var chatBurstGolden = func() string {
	var b strings.Builder
	for i := 0; i < 50; i++ {
		if i%17 == 5 {
			// normalizeSSEChunk: content null -> "", reasoning aliases mirrored,
			// reasoning_details synthesised, top-level usage:null dropped.
			b.WriteString(`data: {"choices":[{"delta":{"content":"","reasoning":"think` + strconv.Itoa(i) +
				`","reasoning_content":"think` + strconv.Itoa(i) + `","reasoning_details":[{"type":"reasoning.text","text":"think` +
				strconv.Itoa(i) + `","id":"reasoning-text-0","format":"unknown","index":0,"signature":null}]},"finish_reason":null,"index":0}],"created":1700000000,"id":"chatcmpl-1","model":"` +
				burstTestModel + `","object":"chat.completion.chunk"}` + "\n\n")
			continue
		}
		b.WriteString(chatContentChunk("t"+strconv.Itoa(i)+" ") + "\n\n")
	}
	// Held finish chunk, re-emitted at stream end (finish_reason preserved:
	// 50 completion tokens < max_tokens 1000).
	b.WriteString(`data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"created":1700000000,"id":"chatcmpl-1","model":"` +
		burstTestModel + `","object":"chat.completion.chunk"}` + "\n\n")
	// Held usage chunk with the provider's reasoning breakdown spliced in.
	b.WriteString(`data: {"choices":[],"created":1700000000,"id":"chatcmpl-1","model":"` + burstTestModel +
		`","object":"chat.completion.chunk","usage":{"completion_tokens":50,"completion_tokens_details":{"reasoning_tokens":7},"prompt_tokens":10,"total_tokens":60}}` + "\n\n")
	// Exactly one terminator; the provider's own [DONE] was swallowed.
	b.WriteString("data: [DONE]\n\n")
	return b.String()
}()

// TestStreamRelay_ChatBurstByteIdentical: a provider that bursts 50 chunks
// (plus finish, usage and its own [DONE]) then completes yields exactly the
// pre-coalescing byte stream, and the persisted request profile accounts for
// it in SSE frames (chunks_out = 53, not the handful of coalesced flushes).
func TestStreamRelay_ChatBurstByteIdentical(t *testing.T) {
	// A clean single-attempt success is sampled at defaultProfileSample (10%);
	// the profile assertions below need this request's row persisted.
	t.Setenv(envProfileSampleRate, "1")
	srv, reg, st, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		for _, c := range burstChatChunks(50) {
			p.writeChunk(t, ctx, req, c)
		}
		p.writeComplete(t, ctx, req, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 7})
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	status, hdr, body := streamRequest(t, ctx, ts, "/v1/chat/completions", burstChatRequest)
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, body)
	}
	if ct := hdr.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content-type = %q", ct)
	}
	if got := string(body); got != chatBurstGolden {
		t.Fatalf("SSE stream diverged from golden.\n--- got ---\n%q\n--- want ---\n%q", got, chatBurstGolden)
	}
	// Terminal semantics, spelled out: finish, usage, then exactly one [DONE].
	events := sseEvents(body)
	if n := len(events); n != 53 {
		t.Fatalf("events = %d, want 53 (50 deltas + finish + usage + [DONE])", n)
	}
	if !strings.Contains(events[50], `"finish_reason":"stop"`) {
		t.Errorf("event 50 should be the held finish chunk: %s", events[50])
	}
	if !strings.Contains(events[51], `"reasoning_tokens":7`) {
		t.Errorf("event 51 should be the held usage chunk with reasoning spliced: %s", events[51])
	}
	if events[52] != "data: [DONE]" {
		t.Errorf("event 52 = %q, want data: [DONE]", events[52])
	}
	if strings.Count(string(body), "[DONE]") != 1 {
		t.Errorf("stream must carry exactly one [DONE]: %q", body)
	}

	// The profiler's relay stamps under coalescing: every frame counts once
	// (53 events over ~9 flushes), bytes_out is the exact byte stream the
	// client received, the terminal flush is stamped and no write failed.
	if !srv.profilerEnabled() {
		t.Fatal("profiler must be on by default with a store")
	}
	var recs []store.RequestProfileRecord
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if recs = st.RequestProfilesSince(time.Time{}); len(recs) == 1 {
			break
		}
	}
	if len(recs) != 1 {
		t.Fatalf("persisted request profiles = %d, want 1", len(recs))
	}
	rec := recs[0]
	if rec.ChunksOut != 53 || rec.BytesOut != int64(len(chatBurstGolden)) {
		t.Fatalf("profile chunks_out=%d bytes_out=%d, want 53 frames / %d bytes (frames, not flushes)",
			rec.ChunksOut, rec.BytesOut, len(chatBurstGolden))
	}
	if rec.DoneFlushedUS == nil || rec.ClientWriteErr {
		t.Fatalf("profile done_flushed_us=%v client_write_err=%v, want stamped / false", rec.DoneFlushedUS, rec.ClientWriteErr)
	}
}

// TestStreamRelay_ChatBurstThenProviderError: chunks queued ahead of a
// mid-stream provider error are all delivered, then the in-band error event,
// and no [DONE].
func TestStreamRelay_ChatBurstThenProviderError(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const n = 20
	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		for i := 0; i < n; i++ {
			p.writeChunk(t, ctx, req, chatContentChunk("w"+strconv.Itoa(i)))
		}
		p.writeError(t, ctx, req, protocol.InferenceErrorMessage{
			Error:       "engine crashed mid-generation",
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
		})
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	status, _, body := streamRequest(t, ctx, ts, "/v1/chat/completions", burstChatRequest)
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, body)
	}
	events := sseEvents(body)
	if len(events) != n+1 {
		t.Fatalf("events = %d, want %d chunks + 1 error: %q", len(events), n, body)
	}
	for i := 0; i < n; i++ {
		if want := chatContentChunk("w" + strconv.Itoa(i)); strings.TrimSpace(want) != events[i] {
			t.Fatalf("event %d = %q, want %q", i, events[i], strings.TrimSpace(want))
		}
	}
	var errEvent struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimPrefix(events[n], "data: ")), &errEvent); err != nil {
		t.Fatalf("last event is not an error object: %q (%v)", events[n], err)
	}
	if errEvent.Error.Type != "provider_error" || errEvent.Error.Message == "" {
		t.Errorf("error event = %+v, want type provider_error with a message", errEvent.Error)
	}
	if strings.Contains(string(body), "[DONE]") {
		t.Errorf("an errored stream must not be terminated with [DONE]: %q", body)
	}
}

// TestStreamRelay_EmitterVariantsBurstThenProviderError: for the Responses,
// completions and Messages relays, a provider error that lands right behind a
// burst (the provider enqueues ErrorCh and then closes ChunkCh, so the relay
// may observe the close mid-drain) is still reported as an in-band error —
// never as a completed/incomplete stream — after every queued delta.
func TestStreamRelay_EmitterVariantsBurstThenProviderError(t *testing.T) {
	const n = 20
	variants := []struct {
		name, path, body string
		// deltas extracts the content deltas in order.
		deltas func(t *testing.T, raw []byte) []string
		// completedMarkers must be absent from an errored stream.
		completedMarkers []string
		// errorMarker must be present in the last frame.
		errorMarker string
	}{
		{
			name: "responses", path: "/v1/responses",
			body: `{"model":"` + burstTestModel + `","input":"hi","stream":true,"max_output_tokens":1000}`,
			deltas: func(t *testing.T, raw []byte) []string {
				var out []string
				for _, ev := range parseTypedSSE(t, raw) {
					if ev.Type == "response.output_text.delta" {
						out = append(out, ev.Delta)
					}
				}
				return out
			},
			completedMarkers: []string{"response.completed", "response.incomplete"},
			errorMarker:      "event: error",
		},
		{
			name: "completions", path: "/v1/completions",
			body: `{"model":"` + burstTestModel + `","prompt":"hi","stream":true,"max_tokens":1000}`,
			deltas: func(t *testing.T, raw []byte) []string {
				var out []string
				for _, ev := range sseEvents(raw) {
					var frame struct {
						Choices []struct {
							Text string `json:"text"`
						} `json:"choices"`
					}
					if json.Unmarshal([]byte(strings.TrimPrefix(ev, "data: ")), &frame) == nil && len(frame.Choices) == 1 {
						out = append(out, frame.Choices[0].Text)
					}
				}
				return out
			},
			completedMarkers: []string{"[DONE]", `"finish_reason":"stop"`},
			errorMarker:      `"error":{`,
		},
		{
			name: "messages", path: "/v1/messages",
			body: `{"model":"` + burstTestModel + `","max_tokens":1000,"messages":[{"role":"user","content":"hi"}],"stream":true}`,
			deltas: func(t *testing.T, raw []byte) []string {
				var out []string
				for _, ev := range parseTypedSSE(t, raw) {
					if ev.Type == "content_block_delta" {
						out = append(out, ev.DeltaText)
					}
				}
				return out
			},
			completedMarkers: []string{"message_stop", "message_delta"},
			errorMarker:      "event: error",
		},
	}
	for _, v := range variants {
		t.Run(v.name, func(t *testing.T) {
			_, reg, _, ts := setupTestServer(t)
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()

			p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
				for i := 0; i < n; i++ {
					p.writeChunk(t, ctx, req, chatContentChunk("e"+strconv.Itoa(i)+" "))
				}
				p.writeError(t, ctx, req, protocol.InferenceErrorMessage{
					Error:       "engine crashed mid-generation",
					StatusCode:  http.StatusInternalServerError,
					FailureCode: protocol.FailureCodeGenerationFailure,
				})
			})
			defer p.conn.Close(websocket.StatusNormalClosure, "")

			status, _, raw := streamRequest(t, ctx, ts, v.path, v.body)
			if status != http.StatusOK {
				t.Fatalf("status = %d body = %s", status, raw)
			}
			deltas := v.deltas(t, raw)
			if len(deltas) != n {
				t.Fatalf("deltas = %d, want %d: %q", len(deltas), n, raw)
			}
			for i, d := range deltas {
				if want := "e" + strconv.Itoa(i) + " "; d != want {
					t.Fatalf("delta %d = %q, want %q", i, d, want)
				}
			}
			events := sseEvents(raw)
			if last := events[len(events)-1]; !strings.Contains(last, v.errorMarker) {
				t.Fatalf("last frame should be the provider error: %q", last)
			}
			if strings.Contains(string(raw), "provider ended without completion") {
				t.Fatalf("provider error misreported as incomplete: %q", raw)
			}
			for _, marker := range v.completedMarkers {
				if strings.Contains(string(raw), marker) {
					t.Fatalf("errored stream must not carry %q: %q", marker, raw)
				}
			}
		})
	}
}

// TestStreamRelay_ChatClientDisconnectDuringBurst: when the consumer drops the
// connection while the provider is still bursting, the relay returns and the
// provider receives a cancel.
func TestStreamRelay_ChatClientDisconnectDuringBurst(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	burstStarted := make(chan struct{})
	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		// Keep bursting on a side goroutine so the read loop stays free to
		// observe the cancel; stop once cancelled (or the test ends).
		go func() {
			for i := 0; ; i++ {
				select {
				case <-p.cancelled:
					return
				case <-ctx.Done():
					return
				default:
				}
				chunk := testEncryptedChunk(t, req, p.pubKey, chatContentChunk("d"+strconv.Itoa(i)))
				data, _ := json.Marshal(chunk)
				if err := p.conn.Write(ctx, websocket.MessageText, data); err != nil {
					return
				}
				if i == 3 {
					close(burstStarted)
				}
				time.Sleep(2 * time.Millisecond)
			}
		}()
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	reqCtx, cancelReq := context.WithCancel(ctx)
	req, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(burstChatRequest))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("stream request: %v", err)
	}
	// Read a little of the stream, then drop the connection mid-burst.
	buf := make([]byte, 64)
	if _, err := resp.Body.Read(buf); err != nil {
		t.Fatalf("first read: %v", err)
	}
	waitClosed(t, burstStarted, 5*time.Second, "provider burst to start")
	cancelReq()
	resp.Body.Close()

	waitClosed(t, p.cancelled, 10*time.Second, "provider cancel after consumer disconnect")
}

// TestStreamRelay_ResponsesBurstSequence: the Responses API variant delivers
// every burst delta in order as output_text.delta events, then completes.
func TestStreamRelay_ResponsesBurstSequence(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const n = 50
	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		for i := 0; i < n; i++ {
			p.writeChunk(t, ctx, req, chatContentChunk("r"+strconv.Itoa(i)+" "))
		}
		p.writeChunk(t, ctx, req, chatFinishChunk("stop"))
		p.writeComplete(t, ctx, req, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: n})
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	body := `{"model":"` + burstTestModel + `","input":"hi","stream":true,"max_output_tokens":1000}`
	status, _, raw := streamRequest(t, ctx, ts, "/v1/responses", body)
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, raw)
	}
	events := parseTypedSSE(t, raw)
	var deltas []string
	for _, ev := range events {
		if ev.Type == "response.output_text.delta" {
			deltas = append(deltas, ev.Delta)
		}
	}
	if len(deltas) != n {
		t.Fatalf("output_text.delta events = %d, want %d", len(deltas), n)
	}
	for i, d := range deltas {
		if want := "r" + strconv.Itoa(i) + " "; d != want {
			t.Fatalf("delta %d = %q, want %q", i, d, want)
		}
	}
	if last := events[len(events)-1]; last.Type != "response.completed" {
		t.Fatalf("last event = %s, want response.completed", last.Type)
	}
	assertSequenceNumbers(t, events)
}

// TestStreamRelay_CompletionsBurstSequence: the legacy completions variant
// delivers every burst delta in order, then a finish event and [DONE].
func TestStreamRelay_CompletionsBurstSequence(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const n = 50
	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		for i := 0; i < n; i++ {
			p.writeChunk(t, ctx, req, chatContentChunk("c"+strconv.Itoa(i)+" "))
		}
		p.writeChunk(t, ctx, req, chatFinishChunk("stop"))
		p.writeComplete(t, ctx, req, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: n})
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	body := `{"model":"` + burstTestModel + `","prompt":"hi","stream":true,"max_tokens":1000}`
	status, _, raw := streamRequest(t, ctx, ts, "/v1/completions", body)
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, raw)
	}
	events := sseEvents(raw)
	if len(events) != n+2 {
		t.Fatalf("events = %d, want %d deltas + finish + [DONE]: %q", len(events), n, raw)
	}
	for i := 0; i < n; i++ {
		var ev struct {
			Choices []struct {
				Text string `json:"text"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(events[i], "data: ")), &ev); err != nil || len(ev.Choices) != 1 {
			t.Fatalf("event %d unparsable: %q (%v)", i, events[i], err)
		}
		if want := "c" + strconv.Itoa(i) + " "; ev.Choices[0].Text != want {
			t.Fatalf("delta %d = %q, want %q", i, ev.Choices[0].Text, want)
		}
	}
	if !strings.Contains(events[n], `"finish_reason":"stop"`) {
		t.Errorf("finish event = %q", events[n])
	}
	if events[n+1] != "data: [DONE]" {
		t.Errorf("terminator = %q", events[n+1])
	}
}

// TestStreamRelay_MessagesBurstSequence: the Anthropic Messages variant
// delivers every burst delta in order inside one text block, then stops.
func TestStreamRelay_MessagesBurstSequence(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const n = 50
	p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
		for i := 0; i < n; i++ {
			p.writeChunk(t, ctx, req, chatContentChunk("m"+strconv.Itoa(i)+" "))
		}
		p.writeChunk(t, ctx, req, chatFinishChunk("stop"))
		p.writeComplete(t, ctx, req, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: n})
	})
	defer p.conn.Close(websocket.StatusNormalClosure, "")

	body := `{"model":"` + burstTestModel + `","max_tokens":1000,"messages":[{"role":"user","content":"hi"}],"stream":true}`
	status, _, raw := streamRequest(t, ctx, ts, "/v1/messages", body)
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, raw)
	}
	events := parseTypedSSE(t, raw)
	var deltas []string
	for _, ev := range events {
		if ev.Type == "content_block_delta" {
			deltas = append(deltas, ev.DeltaText)
		}
	}
	if len(deltas) != n {
		t.Fatalf("content_block_delta events = %d, want %d", len(deltas), n)
	}
	for i, d := range deltas {
		if want := "m" + strconv.Itoa(i) + " "; d != want {
			t.Fatalf("delta %d = %q, want %q", i, d, want)
		}
	}
	types := make([]string, 0, len(events))
	for _, ev := range events {
		types = append(types, ev.Type)
	}
	if types[0] != "message_start" || types[len(types)-1] != "message_stop" {
		t.Fatalf("event envelope = %v", types)
	}
}

// typedSSEEvent is the subset of an `event:`-typed SSE frame these tests
// inspect.
type typedSSEEvent struct {
	Type      string
	Seq       int
	Delta     string // Responses: output_text.delta payload
	DeltaText string // Messages: content_block_delta text
}

var sseEventLine = regexp.MustCompile(`(?m)^event: (\S+)$`)

func parseTypedSSE(t *testing.T, raw []byte) []typedSSEEvent {
	t.Helper()
	var out []typedSSEEvent
	for _, group := range sseEvents(raw) {
		m := sseEventLine.FindStringSubmatch(group)
		if m == nil {
			t.Fatalf("frame without event line: %q", group)
		}
		dataIdx := strings.Index(group, "data: ")
		if dataIdx < 0 {
			t.Fatalf("frame without data line: %q", group)
		}
		var payload struct {
			Type  string `json:"type"`
			Seq   int    `json:"sequence_number"`
			Delta any    `json:"delta"`
		}
		if err := json.Unmarshal([]byte(group[dataIdx+len("data: "):]), &payload); err != nil {
			t.Fatalf("frame data unparsable: %q (%v)", group, err)
		}
		ev := typedSSEEvent{Type: m[1], Seq: payload.Seq}
		switch d := payload.Delta.(type) {
		case string:
			ev.Delta = d
		case map[string]any:
			ev.DeltaText, _ = d["text"].(string)
		}
		if ev.Type != payload.Type {
			t.Fatalf("event line %q disagrees with payload type %q", ev.Type, payload.Type)
		}
		out = append(out, ev)
	}
	return out
}

// assertSequenceNumbers checks Responses events are numbered 0..n-1 in order.
func assertSequenceNumbers(t *testing.T, events []typedSSEEvent) {
	t.Helper()
	for i, ev := range events {
		if ev.Seq != i {
			t.Fatalf("event %d (%s) has sequence_number %d", i, ev.Type, ev.Seq)
		}
	}
}
