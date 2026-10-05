package inference_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestInferencePreludeNormalizesSingleStopForSwiftProtocol(t *testing.T) {
	srv, _ := testServer(t)
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(
			`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END","extension":{"exact":9007199254740993,"decimal":0.10000000000000001},"metadata":{"tag":"synthetic-caller"}}`))
	response := httptest.NewRecorder()
	prelude, ok := srv.NewPreludeParser().Parse(response, request)
	if !ok {
		t.Fatalf("prelude failed: %s", response.Body.String())
	}
	if !prelude.Body.Dirty {
		t.Fatal("stop normalization did not mark the forward body dirty")
	}
	rawBody, err := prelude.Body.Current()
	if err != nil {
		t.Fatal(err)
	}
	var forwarded map[string]any
	if err := json.Unmarshal(rawBody, &forwarded); err != nil {
		t.Fatal(err)
	}
	stops, ok := forwarded["stop"].([]any)
	if _, exists := forwarded["metadata"]; exists {
		t.Error("caller metadata remained in the provider body")
	}
	if !ok || len(stops) != 1 || stops[0] != "END" {
		t.Fatalf("forwarded stop = %#v", forwarded["stop"])
	}
	for _, literal := range []string{"9007199254740993", "0.10000000000000001"} {
		if !bytes.Contains(rawBody, []byte(literal)) {
			t.Fatalf("forwarded body lost exact numeric literal %s: %s", literal, rawBody)
		}
	}
}
