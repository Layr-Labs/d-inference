package api

import (
	"reflect"
	"testing"
)

func TestMapQuantizationToOpenRouter(t *testing.T) {
	cases := map[string]string{
		"4bit":         "int4",
		"4-bit":        "int4",
		"8bit":         "int8",
		"6bit":         "fp6",
		"3bit":         "int4",
		"2bit":         "int4",
		"bf16":         "bf16",
		"fp16":         "fp16",
		"float16":      "fp16",
		"bfloat16":     "bf16",
		"int8":         "int8",
		"4bit-gs64":    "int4", // tolerate descriptor suffixes
		"":             "",
		"weird-format": "",
	}
	for in, want := range cases {
		if got := mapQuantizationToOpenRouter(in); got != want {
			t.Errorf("mapQuantizationToOpenRouter(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDeriveModalities(t *testing.T) {
	in, out := deriveModalities("text", nil)
	if !reflect.DeepEqual(in, []string{"text"}) || !reflect.DeepEqual(out, []string{"text"}) {
		t.Errorf("text model = (%v,%v), want ([text],[text])", in, out)
	}

	in, out = deriveModalities("text", []string{"tools", "vision"})
	if !reflect.DeepEqual(in, []string{"text", "image"}) {
		t.Errorf("vision input = %v, want [text image]", in)
	}
	if !reflect.DeepEqual(out, []string{"text"}) {
		t.Errorf("vision output = %v, want [text]", out)
	}

	in, out = deriveModalities("embedding", nil)
	if !reflect.DeepEqual(in, []string{"text"}) || !reflect.DeepEqual(out, []string{"embedding"}) {
		t.Errorf("embedding = (%v,%v), want ([text],[embedding])", in, out)
	}

	in, _ = deriveModalities("text", []string{"video"})
	if !reflect.DeepEqual(in, []string{"text", "video"}) {
		t.Errorf("video input = %v, want [text video]", in)
	}

	in, _ = deriveModalities("text", []string{"video_input"})
	if !reflect.DeepEqual(in, []string{"text", "video"}) {
		t.Errorf("video_input alias = %v, want [text video]", in)
	}

	// Gemma 4-style: image + audio + video together, order preserved, deduped.
	in, _ = deriveModalities("text", []string{"vision", "audio", "video", "video"})
	if !reflect.DeepEqual(in, []string{"text", "image", "audio", "video"}) {
		t.Errorf("multimodal input = %v, want [text image audio video]", in)
	}
}

func TestSupportedFeaturesFromCapabilities(t *testing.T) {
	// Aliases map onto OpenRouter's vocabulary; result is sorted + deduped.
	got := supportedFeaturesFromCapabilities([]string{"function_calling", "tools", "thinking", "json_schema"})
	want := []string{"reasoning", "structured_outputs", "tools"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("features = %v, want %v", got, want)
	}

	if got := supportedFeaturesFromCapabilities(nil); got != nil {
		t.Errorf("nil caps = %v, want nil", got)
	}
	if got := supportedFeaturesFromCapabilities([]string{"unknown_cap"}); got != nil {
		t.Errorf("unknown-only caps = %v, want nil", got)
	}
}

func TestDefaultSamplingParameters(t *testing.T) {
	got := defaultSamplingParameters()
	// Only parameters the Swift inference engine actually honors should be
	// advertised; OpenRouter-valid-but-unhonored ones must be excluded.
	honored := map[string]bool{
		"temperature": true, "top_p": true, "top_k": true,
		"frequency_penalty": true, "presence_penalty": true,
		"repetition_penalty": true, "stop": true, "seed": true,
		"max_tokens": true,
	}
	if len(got) == 0 {
		t.Fatal("expected non-empty sampling parameters")
	}
	gotSet := map[string]bool{}
	for _, p := range got {
		gotSet[p] = true
		if !honored[p] {
			t.Errorf("advertised sampling parameter %q is not honored by the provider", p)
		}
	}
	// These are OpenRouter-valid but NOT decoded by the Swift provider — must
	// not be advertised.
	for _, p := range []string{"min_p", "top_a", "logit_bias"} {
		if gotSet[p] {
			t.Errorf("must not advertise %q (provider silently ignores it)", p)
		}
	}
}

func TestBuildModelPricing(t *testing.T) {
	p := buildModelPricing(DefaultInputPricePerMillionForTest(), 200_000)
	if p.Prompt != "0.00000005" {
		t.Errorf("prompt = %q, want 0.00000005", p.Prompt)
	}
	if p.Completion != "0.0000002" {
		t.Errorf("completion = %q, want 0.0000002", p.Completion)
	}
	if p.Image != "0" || p.Request != "0" || p.InputCacheRead != "0" {
		t.Errorf("image/request/input_cache_read should default to \"0\", got %q/%q/%q", p.Image, p.Request, p.InputCacheRead)
	}
}

// DefaultInputPricePerMillionForTest mirrors the payments default so the test
// stays readable without importing the constant directly here.
func DefaultInputPricePerMillionForTest() int64 { return 50_000 }
