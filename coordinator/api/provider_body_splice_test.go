package api

import (
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// legacySealCacheBust is the pre-fast-path implementation of the protocol-0
// cache-bust seal: decode into RawMessages, set the key, re-encode.
func legacySealCacheBust(t *testing.T, body []byte, key string) []byte {
	t.Helper()
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("legacy seal decode: %v", err)
	}
	keyJSON, _ := json.Marshal(key)
	parsed["prompt_cache_key"] = keyJSON
	sealed, err := httpresponse.MarshalBody(parsed)
	if err != nil {
		t.Fatal(err)
	}
	return sealed
}
