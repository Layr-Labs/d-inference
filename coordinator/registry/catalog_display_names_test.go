package registry

import (
	"io"
	"log/slog"
	"reflect"
	"testing"
)

func TestCatalogDisplayNames(t *testing.T) {
	r := New(slog.New(slog.NewTextHandler(io.Discard, nil)))

	if got := r.CatalogDisplayNames(); len(got) != 0 {
		t.Fatalf("no catalog: got %v, want empty", got)
	}

	r.SetModelCatalog([]CatalogEntry{
		{ID: "EigenLabs/Qwen3.8-27B-4bit-mtp", DisplayName: "Qwen 3.8 27B", Quantization: "fp4"},
		{ID: "qwen3.6-35b-a3b-vl-mtp-mxfp8", DisplayName: "  Qwen 3.6 35B A3B  "}, // trimmed
		{ID: "gpt-oss-20b", DisplayName: "gpt-oss-20b"},                           // repeats the id: not a display name
		{ID: "local-experiment"},               // none published
		{ID: "blank-name", DisplayName: "   "}, // whitespace is none
		// A rollout alias's desired + previous builds share the public name;
		// quantization tells them apart.
		{ID: "gemma-4-26b-qat-4bit", DisplayName: "Gemma 4 26B", Quantization: "4bit"},
		{ID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Quantization: "8bit"},
		// Same name AND same quantization (or none): no honest label exists.
		{ID: "llama-x-a", DisplayName: "Llama X", Quantization: "4bit"},
		{ID: "llama-x-b", DisplayName: "Llama X", Quantization: "4bit"},
		{ID: "llama-x-c", DisplayName: "Llama X", Quantization: "8bit"},
		{ID: "mistral-y-a", DisplayName: "Mistral Y"},
		{ID: "mistral-y-b", DisplayName: "Mistral Y"},
	})
	want := map[string]string{
		"EigenLabs/Qwen3.8-27B-4bit-mtp": "Qwen 3.8 27B",
		"qwen3.6-35b-a3b-vl-mtp-mxfp8":   "Qwen 3.6 35B A3B",
		"gemma-4-26b-qat-4bit":           "Gemma 4 26B (4bit)",
		"gemma-4-26b":                    "Gemma 4 26B (8bit)",
		"llama-x-c":                      "Llama X (8bit)",
	}
	got := r.CatalogDisplayNames()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("CatalogDisplayNames() = %v, want %v", got, want)
	}

	// The returned map is a copy: mutating it must not touch the catalog.
	got["gpt-oss-20b"] = "GPT-OSS 20B"
	if again := r.CatalogDisplayNames(); !reflect.DeepEqual(again, want) {
		t.Fatalf("catalog mutated through returned map: %v", again)
	}

	r.SetModelCatalog(nil)
	if got := r.CatalogDisplayNames(); len(got) != 0 {
		t.Fatalf("catalog disabled: got %v, want empty", got)
	}
}
