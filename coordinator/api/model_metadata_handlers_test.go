package api

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAdminModelMetadataActionsSetValidateAndClear(t *testing.T) {
	for _, test := range []struct {
		name                 string
		action               string
		metadataKey          string
		setBody              string
		want                 string
		invalidBody          string
		feedValue            func(string, map[string]any) string
		wantAfterClear       string
		clearWithEmptyString bool
	}{
		{
			name:                 "deprecation date",
			action:               "deprecation",
			metadataKey:          "deprecation_date",
			setBody:              `{"deprecation_date":"2026-06-01"}`,
			want:                 "2026-06-01",
			invalidBody:          `{"deprecation_date":"June 1 2026"}`,
			clearWithEmptyString: true,
		},
		{
			name:           "OpenRouter slug",
			action:         "openrouter-slug",
			metadataKey:    "openrouter_slug",
			setBody:        `{"slug":"qwen/qwen3.5-9b"}`,
			want:           "qwen/qwen3.5-9b",
			feedValue:      openRouterSlug,
			wantAfterClear: "mlx-community/metadata-model",
		},
		{
			name:           "Hugging Face ID",
			action:         "hugging-face-id",
			metadataKey:    huggingFaceIDMetadataKey,
			setBody:        `{"hugging_face_id":"  EigenLabs/Metadata-Model  "}`,
			want:           "EigenLabs/Metadata-Model",
			feedValue:      huggingFaceIDForModel,
			wantAfterClear: "mlx-community/metadata-model",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			const modelID = "mlx-community/metadata-model"
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{})
			srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
			srv.SetAdminKey("admin-key")
			seedMetadataActionModel(t, st, modelID)

			call := func(body string) *httptest.ResponseRecorder {
				req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/"+test.action, bytes.NewBufferString(body))
				req.Header.Set("Authorization", "Bearer admin-key")
				rec := httptest.NewRecorder()
				srv.Handler().ServeHTTP(rec, req)
				return rec
			}

			if rec := call(test.setBody); rec.Code != http.StatusOK {
				t.Fatalf("set status = %d, want 200; body=%s", rec.Code, rec.Body.String())
			}
			record, err := st.GetModelRegistryRecord(modelID)
			if err != nil {
				t.Fatal(err)
			}
			if got := record.Metadata[test.metadataKey]; got != test.want {
				t.Fatalf("metadata[%q] = %v, want %q", test.metadataKey, got, test.want)
			}
			if record.Metadata["tier"] != "test" {
				t.Fatalf("set clobbered existing metadata: %+v", record.Metadata)
			}
			if test.feedValue != nil {
				if got := test.feedValue(modelID, record.Metadata); got != test.want {
					t.Fatalf("feed value = %q, want %q", got, test.want)
				}
			}

			if test.invalidBody != "" {
				if rec := call(test.invalidBody); rec.Code != http.StatusBadRequest {
					t.Fatalf("invalid value status = %d, want 400; body=%s", rec.Code, rec.Body.String())
				}
				record, err = st.GetModelRegistryRecord(modelID)
				if err != nil {
					t.Fatal(err)
				}
				if got := record.Metadata[test.metadataKey]; got != test.want {
					t.Fatalf("invalid update changed metadata[%q] to %v", test.metadataKey, got)
				}
			}

			if rec := call(""); rec.Code != http.StatusOK {
				t.Fatalf("clear status = %d, want 200; body=%s", rec.Code, rec.Body.String())
			}
			assertMetadataActionCleared(t, st, modelID, test.metadataKey, test.feedValue, test.wantAfterClear)

			if test.clearWithEmptyString {
				if rec := call(test.setBody); rec.Code != http.StatusOK {
					t.Fatalf("reset status = %d, want 200; body=%s", rec.Code, rec.Body.String())
				}
				if rec := call(`{"deprecation_date":""}`); rec.Code != http.StatusOK {
					t.Fatalf("empty-string clear status = %d, want 200; body=%s", rec.Code, rec.Body.String())
				}
				assertMetadataActionCleared(t, st, modelID, test.metadataKey, nil, "")
			}
		})
	}
}

func seedMetadataActionModel(t *testing.T, st store.Store, modelID string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Metadata Model", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Metadata: map[string]any{"tier": "test"},
	}
	version := &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
}

func assertMetadataActionCleared(
	t *testing.T,
	st store.Store,
	modelID, metadataKey string,
	feedValue func(string, map[string]any) string,
	wantFeedValue string,
) {
	t.Helper()
	record, err := st.GetModelRegistryRecord(modelID)
	if err != nil {
		t.Fatal(err)
	}
	if _, present := record.Metadata[metadataKey]; present {
		t.Fatalf("metadata[%q] was not cleared: %+v", metadataKey, record.Metadata)
	}
	if record.Metadata["tier"] != "test" {
		t.Fatalf("clear clobbered existing metadata: %+v", record.Metadata)
	}
	if feedValue != nil {
		if got := feedValue(modelID, record.Metadata); got != wantFeedValue {
			t.Fatalf("feed value after clear = %q, want %q", got, wantFeedValue)
		}
	}
}
