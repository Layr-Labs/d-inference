package main

import (
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/coordinator/internal/store"
)

func TestSeedModelCatalogRemovesRetiredProviderModels(t *testing.T) {
	st := store.NewMemory("")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	retired := []store.SupportedModel{
		{
			ID:          "black-forest-labs/FLUX.1-schnell",
			S3Name:      "flux-4b",
			DisplayName: "Flux 4B",
			ModelType:   "image",
			Active:      true,
		},
		{
			ID:          "cohere/command-audio-stt",
			S3Name:      "cohere-stt",
			DisplayName: "Cohere STT",
			ModelType:   "transcription",
			Active:      true,
		},
	}
	for _, model := range retired {
		if err := st.SetSupportedModel(&model); err != nil {
			t.Fatalf("SetSupportedModel(%q): %v", model.ID, err)
		}
	}

	keep := store.SupportedModel{
		ID:          "mlx-community/gemma-4-26b-a4b-it-8bit",
		S3Name:      "gemma-4-26b-a4b-it-8bit",
		DisplayName: "Gemma 4 26B",
		ModelType:   "text",
		Active:      true,
	}
	if err := st.SetSupportedModel(&keep); err != nil {
		t.Fatalf("SetSupportedModel(%q): %v", keep.ID, err)
	}

	seedModelCatalog(st, logger)

	models := st.ListSupportedModels()
	byID := make(map[string]store.SupportedModel, len(models))
	for _, model := range models {
		byID[model.ID] = model
	}
	for _, model := range retired {
		if _, ok := byID[model.ID]; ok {
			t.Fatalf("retired model %q remained in catalog", model.ID)
		}
	}
	if _, ok := byID[keep.ID]; !ok {
		t.Fatalf("supported model %q was removed", keep.ID)
	}
	if _, ok := byID["qwen3.5-27b-claude-opus-8bit"]; !ok {
		t.Fatalf("seeded text model missing")
	}
}
