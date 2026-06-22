package api

import "testing"

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

func TestVisionRejectRemoteEnabled_KillSwitch(t *testing.T) {
	if !visionRejectRemoteEnabled() {
		t.Error("default (unset) must be ON")
	}
	t.Setenv("DARKBLOOM_VISION_REJECT_REMOTE_URLS", "false")
	if visionRejectRemoteEnabled() {
		t.Error("=false must disable")
	}
	t.Setenv("DARKBLOOM_VISION_REJECT_REMOTE_URLS", "0")
	if visionRejectRemoteEnabled() {
		t.Error("=0 must disable")
	}
	t.Setenv("DARKBLOOM_VISION_REJECT_REMOTE_URLS", "true")
	if !visionRejectRemoteEnabled() {
		t.Error("=true must enable")
	}
}
