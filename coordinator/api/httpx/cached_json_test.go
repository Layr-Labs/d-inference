package httpx

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEncodeCachedJSONMatchesWriteJSON(t *testing.T) {
	v := map[string]any{"b": []int{1, 2}, "a": "x<y&z", "n": nil}
	rec := httptest.NewRecorder()
	WriteJSON(rec, http.StatusOK, v)
	body, err := EncodeCachedJSON(v)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rec.Body.Bytes(), body) {
		t.Fatalf("cached = %q, original = %q", body, rec.Body.Bytes())
	}
	hit := httptest.NewRecorder()
	WriteCachedJSON(hit, body)
	if hit.Code != rec.Code || hit.Header().Get("Content-Type") != rec.Header().Get("Content-Type") || !bytes.Equal(hit.Body.Bytes(), rec.Body.Bytes()) {
		t.Fatal("cached response differs from original")
	}
}
