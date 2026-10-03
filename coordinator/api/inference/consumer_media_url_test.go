package inference

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func msg(content any) map[string]any { return map[string]any{"role": "user", "content": content} }

// TestRejectRemoteMediaURLsIsUnconditional pins the gate as unconditional on
// every surface. The generic (completions + Anthropic) surface never fetches,
// so forwarding a remote URL there can only end in a provider-side 400 — the
// retired DARKBLOOM_VISION_REJECT_REMOTE_URLS switch must never re-enable it.
func TestRejectRemoteMediaURLsIsUnconditional(t *testing.T) {
	s := &Owner{logger: quietLogger()}
	remotePart := map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://example.com/x.png"}}
	remote := map[string]any{"messages": []any{msg([]any{remotePart})}}

	// The retired flag is read nowhere: no value of it may disable the gate.
	for _, flag := range []string{"", "false", "0", "true"} {
		t.Setenv("DARKBLOOM_VISION_REJECT_REMOTE_URLS", flag)
		w := httptest.NewRecorder()
		if !s.rejectRemoteMediaURLs(w, plainReq(), remote, "test", "test", true, false) {
			t.Fatalf("flag=%q: a remote media URL must always be rejected pre-dispatch", flag)
		}
		if w.Code != http.StatusBadRequest {
			t.Errorf("flag=%q: status = %d, want 400", flag, w.Code)
		}
	}

	// Unconditional on the flag, still conditional on the request: non-vision
	// bodies and inline data: URIs pass untouched.
	if s.rejectRemoteMediaURLs(httptest.NewRecorder(), plainReq(), remote, "test", "test", false, false) {
		t.Error("non-vision requests must never be gated")
	}
	inline := map[string]any{"messages": []any{msg([]any{
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}},
	})}}
	if s.rejectRemoteMediaURLs(httptest.NewRecorder(), plainReq(), inline, "test", "test", true, false) {
		t.Error("inline data: URI must pass")
	}
}
