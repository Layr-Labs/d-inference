package inference_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// The caller's safety and cache-routing hints leave the provider-bound body,
// while an identically named nested field remains semantic input.
func TestProviderIdentityRoutingHintsAreNotForwarded(t *testing.T) {
	srv, _ := testServer(t)
	for _, key := range []string{"safety_identifier", "prompt_cache_key"} {
		t.Run(key, func(t *testing.T) {
			body := fmt.Sprintf(`{"model":"privacy-model",%q:"caller-identifier","extension":{%q:"semantic-value"},"messages":[{"role":"user","content":"keep semantic text"}],"max_tokens":16}`, key, key)
			w := httptest.NewRecorder()
			prelude, ok := srv.NewPreludeParser().Parse(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)))
			if !ok {
				t.Fatalf("prelude rejected input: status=%d", w.Code)
			}
			got, err := prelude.Body.Current()
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := inreq.DecodeInferenceJSONObject(got)
			if err != nil {
				t.Fatal(err)
			}
			if _, ok := parsed[key]; ok {
				t.Errorf("caller identifier %s still forwarded", key)
			}
			if !reflect.DeepEqual(parsed["extension"], map[string]any{key: "semantic-value"}) {
				t.Fatal("nested semantic input removed")
			}
		})
	}
}
