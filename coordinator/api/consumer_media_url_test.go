package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

// C4: media parts carrying a remote/non-data: URL must be detected so the
// coordinator can reject them pre-dispatch (the provider VLM path is data:-only).

func TestMediaPartURLString_AllShapes(t *testing.T) {
	cases := []struct {
		name    string
		part    map[string]any
		wantRef string
		wantMed bool
	}{
		{"image_url object remote", map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://x/a.png"}}, "https://x/a.png", true},
		{"image_url bare string", map[string]any{"type": "image_url", "image_url": "https://x/b.png"}, "https://x/b.png", true},
		{"image_url data uri", map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}}, "data:image/png;base64,AAAA", true},
		{"input_image string", map[string]any{"type": "input_image", "image_url": "https://x/c.png"}, "https://x/c.png", true},
		{"video_url object", map[string]any{"type": "video_url", "video_url": map[string]any{"url": "https://x/v.mp4"}}, "https://x/v.mp4", true},
		{"anthropic image url", map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": "https://x/d.png"}}, "https://x/d.png", true},
		{"anthropic image base64 inline", map[string]any{"type": "image", "source": map[string]any{"type": "base64", "data": "AAAA"}}, "data:anthropic-inline-base64", true},
		{"text part not media", map[string]any{"type": "text", "text": "hi"}, "", false},
	}
	for _, c := range cases {
		ref, isMedia := mediaPartURLString(c.part)
		if isMedia != c.wantMed || ref != c.wantRef {
			t.Errorf("%s: got (%q,%v) want (%q,%v)", c.name, ref, isMedia, c.wantRef, c.wantMed)
		}
	}
}

func msg(content any) map[string]any { return map[string]any{"role": "user", "content": content} }

func TestValidateMediaParts_RejectsRemote(t *testing.T) {
	remote := []any{map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://example.com/x.png"}}}
	dataURI := []any{map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}}}
	mixed := []any{
		map[string]any{"type": "text", "text": "describe"},
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}},
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://example.com/y.png"}},
	}

	if ref, ok := validateMediaParts(map[string]any{"messages": []any{msg(remote)}}); ok || ref == "" {
		t.Errorf("remote URL must be rejected; got ref=%q ok=%v", ref, ok)
	}
	if _, ok := validateMediaParts(map[string]any{"messages": []any{msg(dataURI)}}); !ok {
		t.Error("data: URI must pass")
	}
	if ref, ok := validateMediaParts(map[string]any{"messages": []any{msg(mixed)}}); ok || ref != "https://example.com/y.png" {
		t.Errorf("mixed body must return the first remote URL; got ref=%q ok=%v", ref, ok)
	}
	// Responses API input[] surface.
	if _, ok := validateMediaParts(map[string]any{"input": []any{map[string]any{"content": remote}}}); ok {
		t.Error("remote URL in Responses input[] must be rejected")
	}
	// Text-only body passes.
	if _, ok := validateMediaParts(map[string]any{"messages": []any{msg("just text")}}); !ok {
		t.Error("text-only body must pass")
	}
	// Anthropic inline base64 passes (not a remote URL).
	anth := []any{map[string]any{"type": "image", "source": map[string]any{"type": "base64", "data": "AAAA"}}}
	if _, ok := validateMediaParts(map[string]any{"messages": []any{msg(anth)}}); !ok {
		t.Error("anthropic inline base64 must pass (only remote refs are rejected in v1)")
	}
}

// TestRejectRemoteMediaURLsIsUnconditional pins the gate as unconditional on
// every surface. The generic (completions + Anthropic) surface never fetches,
// so forwarding a remote URL there can only end in a provider-side 400 — the
// retired DARKBLOOM_VISION_REJECT_REMOTE_URLS switch must never re-enable it.
func TestRejectRemoteMediaURLsIsUnconditional(t *testing.T) {
	s := &Server{logger: quietLogger()}
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

func TestTruncateMediaRef(t *testing.T) {
	// "é" is 2 bytes; placed at offset 199 it straddles the 200-byte cut, so a
	// naive ref[:200] ends on a partial rune that encoding/json renders U+FFFD.
	straddling := strings.Repeat("a", 199) + "é" + strings.Repeat("b", 50)
	cases := []struct {
		name string
		ref  string
		want string
	}{
		{"short ref verbatim", "https://example.com/a.png", "https://example.com/a.png"},
		{"exactly at the cap verbatim", strings.Repeat("a", 200), strings.Repeat("a", 200)},
		{"ascii over the cap", strings.Repeat("a", 201), strings.Repeat("a", 200) + "…"},
		{"multibyte rune straddling the cut is dropped", straddling, strings.Repeat("a", 199) + "…"},
	}
	for _, c := range cases {
		got := truncateMediaRef(c.ref)
		if got != c.want {
			t.Errorf("%s: truncateMediaRef() = %q, want %q", c.name, got, c.want)
		}
		if !utf8.ValidString(got) {
			t.Errorf("%s: truncateMediaRef() emitted invalid UTF-8: %q", c.name, got)
		}
	}
}
