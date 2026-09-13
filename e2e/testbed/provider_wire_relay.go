package testbed

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// ProviderWireEvent deliberately omits auth tokens, keys, nonces, scopes,
// token-chain hashes, sealed bodies and model-generated response chunks.
// A received receipt is NOT an accepted receipt: callers must correlate it with
// the coordinator's accepted lifecycle counters and terminal usage.
type ProviderWireEvent struct {
	Connection int                        `json:"connection"`
	Direction  string                     `json:"direction"`
	At         time.Time                  `json:"at"`
	Type       string                     `json:"type"`
	RequestID  string                     `json:"request_id,omitempty"`
	Fields     map[string]json.RawMessage `json:"fields,omitempty"`
}

// ProviderWireRelay is a bounded, transparent test-only loopback WS hop. One
// pump per direction preserves frame order. Neither authentication nor payload
// encryption is replaced, and no provider frame is synthesized.
type ProviderWireRelay struct {
	mu          sync.Mutex
	events      []ProviderWireEvent
	connections int
	dropped     int
	storedBytes int
	server      *httptest.Server
	cancel      context.CancelFunc
}

func (r *ProviderWireRelay) Start(coordinatorURL string) string {
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel = cancel
	upstream := "ws" + strings.TrimPrefix(coordinatorURL, "http") + "/ws/provider"
	r.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/ws/provider" {
			http.NotFound(w, req)
			return
		}
		// Forward the authentication header; the real server still validates both
		// the HTTP header and the registration's provider token in its normal path.
		header := http.Header{}
		header.Set("Authorization", req.Header.Get("Authorization"))
		back, _, err := websocket.Dial(ctx, upstream, &websocket.DialOptions{HTTPHeader: header})
		if err != nil {
			http.Error(w, "coordinator connection failed", http.StatusBadGateway)
			return
		}
		defer back.CloseNow()
		front, err := websocket.Accept(w, req, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer front.CloseNow()
		front.SetReadLimit(16 << 20)
		back.SetReadLimit(16 << 20)
		r.mu.Lock()
		r.connections++
		id := r.connections
		r.mu.Unlock()
		connectionCtx, end := context.WithCancel(ctx)
		defer end()
		done := make(chan struct{}, 2)
		pump := func(src, dst *websocket.Conn, direction string) {
			defer func() { done <- struct{}{} }()
			for {
				kind, data, err := src.Read(connectionCtx)
				if err != nil {
					return
				}
				r.observe(id, direction, data)
				if err := dst.Write(connectionCtx, kind, data); err != nil {
					return
				}
			}
		}
		go pump(front, back, "provider_to_coordinator")
		go pump(back, front, "coordinator_to_provider")
		<-done
		end()
		front.CloseNow()
		back.CloseNow()
		<-done
	}))
	return r.server.URL
}

func (r *ProviderWireRelay) Close() {
	if r.cancel != nil {
		r.cancel()
	}
	if r.server != nil {
		r.server.Close()
	}
}

func (r *ProviderWireRelay) Snapshot() ([]ProviderWireEvent, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// JSON roundtrip owns all nested values, so live appends cannot alter a report.
	raw, _ := json.Marshal(r.events)
	var events []ProviderWireEvent
	_ = json.Unmarshal(raw, &events)
	return events, r.dropped
}

func (r *ProviderWireRelay) observe(connection int, direction string, data []byte) {
	event, ok := summarizeProviderFrame(data)
	if !ok {
		return
	}
	event.Connection, event.Direction, event.At = connection, direction, time.Now().UTC()
	r.mu.Lock()
	defer r.mu.Unlock()
	encoded, _ := json.Marshal(event)
	if len(r.events) >= 4096 || len(encoded) > 64<<10 || r.storedBytes+len(encoded) > 16<<20 {
		r.dropped++
		return
	}
	r.storedBytes += len(encoded)
	r.events = append(r.events, event)
}

func summarizeProviderFrame(data []byte) (ProviderWireEvent, bool) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil {
		return ProviderWireEvent{}, false
	}
	event := ProviderWireEvent{Fields: map[string]json.RawMessage{}}
	_ = json.Unmarshal(raw["type"], &event.Type)
	_ = json.Unmarshal(raw["request_id"], &event.RequestID)
	copyFields := func(names ...string) {
		for _, key := range names {
			if value, ok := raw[key]; ok {
				event.Fields[key] = value
			}
		}
	}
	present := func(key string) {
		value := len(raw[key]) > 0 && string(raw[key]) != `""` && string(raw[key]) != "null"
		event.Fields[key+"_present"], _ = json.Marshal(value)
	}
	switch event.Type {
	case "inference_request":
		copyFields("prefix_cache_protocol", "cache_receipt_boundary_mode", "tool_schema_metadata_protocol")
		present("cache_scope")
		present("cache_receipt_nonce")
		present("encrypted_body")
	case "prefix_cache_lookup_v2", "prefix_cache_ready_v2":
		copyFields("model_id", "model_aggregate_hash", "prompt_contract_id", "cache_epoch", "cache_seq", "outcome", "tier", "required_recompute_tokens", "expected_prefill_tokens_saved", "stage_ms")
		// Only positions survive; hashes and receipt nonces do not.
		for _, key := range []string{"prompt_anchor", "matched_anchor"} {
			var anchor struct {
				TokenCount int `json:"token_count"`
			}
			if json.Unmarshal(raw[key], &anchor) == nil {
				event.Fields[key+"_tokens"], _ = json.Marshal(anchor.TokenCount)
			}
		}
		var anchors []struct {
			TokenCount int `json:"token_count"`
		}
		if json.Unmarshal(raw["ready_anchors"], &anchors) == nil {
			positions := []int{}
			for _, a := range anchors {
				positions = append(positions, a.TokenCount)
			}
			event.Fields["ready_positions"], _ = json.Marshal(positions)
		}
	case "inference_complete":
		copyProfileFields(event.Fields, raw)
	case "inference_error":
		copyFields("status_code", "terminal_cause", "failure_code")
		copyProfileFields(event.Fields, raw)
	case "cancel", "inference_accepted":
	case "register":
		copyFields("version", "prefix_cache_protocol", "prefix_cache_v2_models", "template_hashes", "encrypted_response_chunks")
		present("auth_token")
		present("public_key")
	default:
		return ProviderWireEvent{}, false
	}
	return event, true
}

func copyProfileFields(out, raw map[string]json.RawMessage) {
	if data, ok := raw["usage"]; ok {
		var usage protocol.UsageInfo
		if json.Unmarshal(data, &usage) == nil {
			out["usage"], _ = json.Marshal(usage)
		}
	}
	if data, ok := raw["profile"]; ok {
		var profile protocol.InferenceProfile
		if json.Unmarshal(data, &profile) == nil {
			out["profile"], _ = json.Marshal(profile)
		}
	}
}
