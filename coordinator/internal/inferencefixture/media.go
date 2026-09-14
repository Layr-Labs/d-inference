package inferencefixture

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"sync/atomic"
	"testing"
)

// testPNG returns a real, decodable 2x2 PNG (passes both the sniff allowlist
// and the header pixel gate).
func PNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

// pngHandler serves a valid PNG and counts hits (for fetched/not-fetched asserts).
func PNGHandler(t *testing.T, hits *int32) http.HandlerFunc {
	img := PNG(t)
	return func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		w.Write(img)
	}
}

func ChatBody(t *testing.T, imageURL string) ([]byte, map[string]any) {
	t.Helper()
	parsed := map[string]any{
		"model": "test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": imageURL}},
		}}},
	}
	raw, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Re-parse so the returned map is independent of the bytes (mirrors prelude).
	var fresh map[string]any
	if err := json.Unmarshal(raw, &fresh); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return raw, fresh
}

func ErrorType(t *testing.T, body []byte) string {
	t.Helper()
	var resp struct {
		Error struct {
			Type string `json:"type"`
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal error body %q: %v", body, err)
	}
	if resp.Error.Code != "" {
		return resp.Error.Code
	}
	return resp.Error.Type
}
