package response_test

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func identityFromTerminal(t *testing.T, chunks ...string) map[string]any {
	t.Helper()
	pr := &registry.PendingRequest{RequestID: "test", MetadataDetails: true, ResponseMetadata: []byte(`{}`)}
	w := httptest.NewRecorder()
	relay := production.NewChatStreamRelay(pr, w, w, nil)
	for _, chunk := range chunks {
		relay.HandleChunk(chunk)
	}
	// Only terminal bytes are needed: the relay has observed the provider
	// envelopes, while its content batch remains private.
	production.WriteChatStreamTerminalError(w, w, pr, "test_error", "test", relay.Identity)
	line := strings.Split(w.Body.String(), "\n")[0]
	var event map[string]any
	if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
		t.Fatalf("terminal event %q: %v", line, err)
	}
	return event
}

func TestChatStreamIdentityObservation(t *testing.T) {
	for _, test := range []struct {
		name, wire string
		created    bool
	}{
		{"bare", `{"id":"native","object":"chat.completion.chunk","created":123,"choices":[]}`, true},
		{"decorated-multiline", "event: message\r\nid: ignored\r\ndata: {\"id\":\"native\",\r\ndata: \"object\":\"chat.completion.chunk\",\"created\":123,\"choices\":[]}", true},
		{"coalesced-and-escaped", ": {\"id\":\"comment\"}\n\ndata: {\"choices\":[{\"delta\":{\"id\":\"nested\"}}]}\n\ndata: {\"id\":\"nat\\u0069ve\",\"created\":123,\"choices\":[]}", true},
		{"created-null", `data: {"id":"native","created":null,"choices":[]}`, false},
		{"created-invalid", `data: {"id":"native","created":"wrong","choices":[]}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			before := time.Now().Unix()
			identity := identityFromTerminal(t, test.wire)
			if identity["id"] != "native" || (identity["created"] == float64(123)) != test.created {
				t.Fatalf("unexpected identity %+v", identity)
			}
			if !test.created && (identity["created"].(float64) < float64(before) || identity["created"].(float64) > float64(time.Now().Unix())) {
				t.Fatal("missing provider creation time did not use terminal time")
			}
			later := identityFromTerminal(t, test.wire, `data: {"id":"later","created":456,"choices":[]}`)
			if later["id"] != "native" || (test.created && later["created"] != float64(123)) {
				t.Fatal("first provider identity overwritten")
			}
		})
	}
	for _, invalid := range []string{
		`data: {"object":"response","id":"responses-id","choices":[]}`,
		`data: {"id":42,"choices":[]}`, `data: {"id":"","choices":[]}`,
		`data: {"metadata":{"id":"nested"},"choices":[]}`, `data: {"id":"not-chat"}`,
		`data: {"id":"incomplete"`, `: data: {"id":"comment","choices":[]}`,
	} {
		identity := identityFromTerminal(t, invalid)
		if identity["id"] != "chatcmpl-test" {
			t.Fatalf("non-envelope id trusted: %q", invalid)
		}
	}
}
