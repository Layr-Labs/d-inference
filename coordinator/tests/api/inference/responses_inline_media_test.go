package inference_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
)

func TestResponsesInlineMediaRejectsRemoteBeforeFetch(t *testing.T) {
	var hits int32
	origin := httptest.NewServer(pngHandler(t, &hits))
	defer origin.Close()
	config := mediafetch.DefaultConfig()
	config.AllowPrivateIPs = true
	config.AllowNonStandardPorts = true
	srv, _ := testServerWithConfig(t, TestServerConfig{MediaFetch: &config})
	makeVisionRoutableProvider(t, srv.registry, "vision", "test")
	for _, toolOutput := range []bool{false, true} {
		t.Run(fmt.Sprintf("tool-output=%t", toolOutput), func(t *testing.T) {
			part := map[string]any{"type": "input_image", "image_url": origin.URL + "/image.png?token=synthetic-marker"}
			item := map[string]any{"role": "user", "content": []any{part}}
			if toolOutput {
				item = map[string]any{"type": "function_call_output", "call_id": "actual", "output": []any{part}}
			}
			body, _ := json.Marshal(map[string]any{"model": "test", "input": []any{item}, "max_output_tokens": 64})
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != 400 {
				t.Fatalf("non-inline media did not fail before dispatch: %d", w.Code)
			}
			if strings.Contains(w.Body.String(), "synthetic-marker") {
				t.Fatal("validation echoed URL contents")
			}
			if atomic.LoadInt32(&hits) != 0 {
				t.Fatal("Responses started remote fetch")
			}
		})
	}
}
