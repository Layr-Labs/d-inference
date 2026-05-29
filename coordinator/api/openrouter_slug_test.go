package api

import "testing"

func TestOpenRouterSlug(t *testing.T) {
	const id = "mlx-community/Qwen3.5-9B-MLX-4bit"

	// Metadata override wins (operator maps onto a canonical marketplace slug).
	if got := openRouterSlug(id, map[string]any{"openrouter_slug": "qwen/qwen3.5-9b"}); got != "qwen/qwen3.5-9b" {
		t.Errorf("override slug = %q, want qwen/qwen3.5-9b", got)
	}
	// Default is the unique model id (collision-free, doc-aligned slug==id).
	if got := openRouterSlug(id, nil); got != id {
		t.Errorf("default slug = %q, want the model id %q", got, id)
	}
	// Blank override falls back to the id.
	if got := openRouterSlug(id, map[string]any{"openrouter_slug": "  "}); got != id {
		t.Errorf("blank override slug = %q, want the model id", got)
	}
	// Two same-named repos under different owners get DISTINCT default slugs.
	a := openRouterSlug("org-a/Foo-7B", nil)
	b := openRouterSlug("org-b/Foo-7B", nil)
	if a == b {
		t.Errorf("default slugs must be unique per id: both = %q", a)
	}
}

func TestOpenRouterIsReady(t *testing.T) {
	if !openRouterIsReady(nil) {
		t.Error("nil metadata should default to ready")
	}
	if !openRouterIsReady(map[string]any{}) {
		t.Error("empty metadata should default to ready")
	}
	if openRouterIsReady(map[string]any{"openrouter_is_ready": false}) {
		t.Error("explicit openrouter_is_ready=false should be not-ready")
	}
	if openRouterIsReady(map[string]any{"openrouter_staged": true}) {
		t.Error("openrouter_staged=true should be not-ready")
	}
	if !openRouterIsReady(map[string]any{"openrouter_staged": false}) {
		t.Error("openrouter_staged=false should be ready")
	}
}

func TestIsNonTextModelType(t *testing.T) {
	// Text-ish and unknown types are NOT excluded (kept in the feed).
	for _, mt := range []string{"", "text", "chat", "Completion", "test", "future-type"} {
		if isNonTextModelType(mt) {
			t.Errorf("isNonTextModelType(%q) = true, want false (should stay in feed)", mt)
		}
	}
	// Known non-text modalities are excluded.
	for _, mt := range []string{"embedding", "tts", "image", "audio", "Rerank"} {
		if !isNonTextModelType(mt) {
			t.Errorf("isNonTextModelType(%q) = false, want true (should be excluded)", mt)
		}
	}
}
