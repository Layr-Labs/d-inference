package api

import "testing"

func TestSlugify(t *testing.T) {
	cases := map[string]string{
		"Qwen3.5-9B-MLX-4bit": "qwen3-5-9b-mlx-4bit",
		"  Hello World  ":     "hello-world",
		"a__b--c":             "a-b-c",
		"UPPER":               "upper",
		"":                    "",
		"---":                 "",
	}
	for in, want := range cases {
		if got := slugify(in); got != want {
			t.Errorf("slugify(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestOpenRouterSlug(t *testing.T) {
	// Metadata override wins.
	if got := openRouterSlug("mlx-community/Qwen3.5-9B", map[string]any{"openrouter_slug": "darkbloom/qwen-9b"}); got != "darkbloom/qwen-9b" {
		t.Errorf("override slug = %q", got)
	}
	// Derived default uses the id tail, namespaced under darkbloom/.
	if got := openRouterSlug("mlx-community/Qwen3.5-9B-MLX-4bit", nil); got != "darkbloom/qwen3-5-9b-mlx-4bit" {
		t.Errorf("derived slug = %q, want darkbloom/qwen3-5-9b-mlx-4bit", got)
	}
	// Blank override falls back to derived.
	if got := openRouterSlug("foo/bar", map[string]any{"openrouter_slug": "  "}); got != "darkbloom/bar" {
		t.Errorf("blank override slug = %q, want darkbloom/bar", got)
	}
	// No slash.
	if got := openRouterSlug("solo", nil); got != "darkbloom/solo" {
		t.Errorf("no-slash slug = %q", got)
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
