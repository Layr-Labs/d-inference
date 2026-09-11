package api

import (
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
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
	// Default rates: $0.05 input, $0.20 output, and the derived 50% cache-read
	// discount ($0.025) per 1M tokens, rendered as OpenRouter per-token USD.
	p := buildModelPricing(payments.DefaultRates())
	if p.Prompt != "0.00000005" {
		t.Errorf("prompt = %q, want 0.00000005", p.Prompt)
	}
	if p.Completion != "0.0000002" {
		t.Errorf("completion = %q, want 0.0000002", p.Completion)
	}
	if p.InputCacheRead != "0.000000025" {
		t.Errorf("input_cache_read = %q, want 0.000000025 (half the prompt rate)", p.InputCacheRead)
	}
	if p.Image != "0" || p.Request != "0" {
		t.Errorf("image/request should be \"0\", got %q/%q", p.Image, p.Request)
	}

	// An explicit cache-read rate is advertised verbatim; zero is a genuinely
	// free SKU and renders as "0".
	free := buildModelPricing(payments.Rates{Input: 50_000, Output: 200_000, CacheRead: 0})
	if free.InputCacheRead != "0" {
		t.Errorf("free cache read = %q, want 0", free.InputCacheRead)
	}
	explicit := buildModelPricing(payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: 30_000})
	if explicit.InputCacheRead != "0.00000003" {
		t.Errorf("explicit cache read = %q, want 0.00000003", explicit.InputCacheRead)
	}
}

// The feed's pricing block must be a pure function of the settlement rates so
// the advertised prices and the debit can never drift apart.
func TestBuildModelPricingMirrorsSettlementRates(t *testing.T) {
	rates := payments.Rates{Input: 123_456, Output: 654_321, CacheRead: 12_345}
	p := buildModelPricing(rates)
	for name, tc := range map[string]struct {
		got  string
		rate int64
	}{
		"prompt":           {p.Prompt, rates.Input},
		"completion":       {p.Completion, rates.Output},
		"input_cache_read": {p.InputCacheRead, rates.CacheRead},
	} {
		if want := payments.FormatPerTokenUSD(tc.rate); tc.got != want {
			t.Errorf("%s = %q, want %q", name, tc.got, want)
		}
	}
}
