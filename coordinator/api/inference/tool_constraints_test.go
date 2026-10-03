package inference

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
			`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END","metadata":{"exact":9007199254740993,"decimal":0.10000000000000001}}`))
	response := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(response, request)
	if !ok {
		t.Fatalf("prelude failed: %s", response.Body.String())
	}
	if !prelude.body.Dirty {
		t.Fatal("stop normalization did not mark the forward body dirty")
	}
	rawBody, err := prelude.body.Current()
	if err != nil {
		t.Fatal(err)
	}
	var forwarded map[string]any
	if err := json.Unmarshal(rawBody, &forwarded); err != nil {
		t.Fatal(err)
	}
	stops, ok := forwarded["stop"].([]any)
	if !ok || len(stops) != 1 || stops[0] != "END" {
		t.Fatalf("forwarded stop = %#v", forwarded["stop"])
	}
	for _, literal := range []string{"9007199254740993", "0.10000000000000001"} {
		if !bytes.Contains(rawBody, []byte(literal)) {
			t.Fatalf("forwarded body lost exact numeric literal %s: %s", literal, rawBody)
		}
	}
}
