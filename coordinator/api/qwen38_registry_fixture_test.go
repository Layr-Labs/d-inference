package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	qwen38ConcreteModel = "mlx-community/Qwen3.8-27B-4bit"
	qwen38PublicAlias   = "qwen/qwen3.8-27b"
	qwen38TargetRev     = "3e6447f082e89cc7f0bc6e5441afd38dfce760ff"
	qwen38MTPModel      = "mlx-community/Qwen3.8-27B-MTP-4bit"
	qwen38MTPRev        = "b643c01b6d3b094e325edb6ebd832e16c486c575"
)

func qwen38RegistryFixture() *store.ModelRegistryEntry {
	return &store.ModelRegistryEntry{
		ID:               qwen38ConcreteModel,
		DisplayName:      "Qwen3.8 27B",
		Family:           "qwen3.8",
		Architecture:     "27B dense VLM",
		Quantization:     "4bit",
		MaxContextLength: 262144,
		MaxOutputLength:  32768,
		MinRAMGB:         48,
		Capabilities:     []string{"tools", "reasoning", "json_mode", "vision", "video"},
		Status:           "active",
		Description:      "Dense Qwen3.8 vision-language model with bounded image and video input.",
		RuntimeParameters: map[string]any{
			"reasoning_parser":       "qwen3",
			"tool_call_parser":       "qwen3_coder",
			"chat_template_required": true,
		},
		Metadata: map[string]any{
			huggingFaceIDMetadataKey: qwen38ConcreteModel,
			"source_revision":        qwen38TargetRev,
			"mtp_artifact_id":        qwen38MTPModel,
			"mtp_source_revision":    qwen38MTPRev,
			"runtime_compatibility":  "provider>=0.8.11",
			"openrouter_slug":        qwen38PublicAlias,
			"openrouter_is_ready":    true,
		},
		CreatedAt: time.Date(2026, 8, 24, 0, 0, 0, 0, time.UTC),
	}
}

func TestInjectModelRuntimeDefaults(t *testing.T) {
	t.Run("fills both parser defaults", func(t *testing.T) {
		parsed := map[string]any{"model": qwen38ConcreteModel}
		if !injectModelRuntimeDefaults(parsed, qwen38RegistryFixture().RuntimeParameters) {
			t.Fatal("expected request defaults to change the body")
		}
		if parsed["reasoning_parser"] != "qwen3" || parsed["tool_call_parser"] != "qwen3_coder" {
			t.Fatalf("parser defaults = %#v", parsed)
		}
		if _, leaked := parsed["chat_template_required"]; leaked {
			t.Fatal("provider/catalog-only runtime parameter leaked into request body")
		}
	})

	t.Run("explicit consumer values win", func(t *testing.T) {
		parsed := map[string]any{
			"reasoning_parser": "deepseek_r1",
			"tool_call_parser": "qwen_xml",
		}
		if injectModelRuntimeDefaults(parsed, qwen38RegistryFixture().RuntimeParameters) {
			t.Fatal("explicit request values should not be changed")
		}
		if parsed["reasoning_parser"] != "deepseek_r1" || parsed["tool_call_parser"] != "qwen_xml" {
			t.Fatalf("explicit values changed: %#v", parsed)
		}
	})

	t.Run("malformed metadata is ignored", func(t *testing.T) {
		parsed := map[string]any{}
		if injectModelRuntimeDefaults(parsed, map[string]any{
			"reasoning_parser": 7,
			"tool_call_parser": "  ",
		}) {
			t.Fatalf("malformed metadata changed request: %#v", parsed)
		}
	})
}

// This fixture pins the intended post-review registration contract without
// mutating a production catalog. It verifies that the generic registry, alias,
// OpenRouter, pricing, modality, and live-capacity surfaces preserve every
// launch-critical Qwen3.8 field.
func TestQwen38RegistrySurfaceFixture(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	entry := qwen38RegistryFixture()
	const version = "2026-08-24-r1"
	files := []store.ModelVersionFile{{
		Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config",
	}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: qwen38ConcreteModel, Version: version,
		R2Prefix:        modelR2Prefix(qwen38ConcreteModel, version),
		AggregateSHA256: testHash, TotalSizeBytes: 17_000_000_000,
		FileCount: len(files), Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(qwen38ConcreteModel, version); err != nil {
		t.Fatal(err)
	}
	if err := st.SetModelPrice("platform", qwen38ConcreteModel, 50_000, 200_000); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: qwen38PublicAlias, DisplayName: entry.DisplayName,
		DesiredBuild: qwen38ConcreteModel, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	build, isAlias, ok := reg.ResolveModel(qwen38PublicAlias)
	if !ok || !isAlias || build != qwen38ConcreteModel {
		t.Fatalf("alias resolution = %q isAlias=%v ok=%v", build, isAlias, ok)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn := connectAndPrepareProvider(
		t, ctx, ts.URL, reg, qwen38ConcreteModel, testPublicKeyB64(), 18.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	t.Run("catalog item", func(t *testing.T) {
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, httptest.NewRequest(
			http.MethodGet, "/v1/models/catalog/"+qwen38ConcreteModel, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var model map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &model); err != nil {
			t.Fatal(err)
		}
		if model["family"] != "qwen3.8" || model["architecture"] != "27B dense VLM" {
			t.Fatalf("identity metadata = %#v", model)
		}
		if int(model["max_context_length"].(float64)) != 262144 ||
			int(model["max_output_length"].(float64)) != 32768 ||
			int(model["min_ram_gb"].(float64)) != 48 {
			t.Fatalf("launch limits = %#v", model)
		}
		runtime, _ := model["runtime_parameters"].(map[string]any)
		if runtime["reasoning_parser"] != "qwen3" || runtime["tool_call_parser"] != "qwen3_coder" || runtime["chat_template_required"] != true {
			t.Fatalf("runtime defaults = %#v", runtime)
		}
		metadata, _ := model["metadata"].(map[string]any)
		if metadata["source_revision"] != qwen38TargetRev || metadata["mtp_artifact_id"] != qwen38MTPModel || metadata["mtp_source_revision"] != qwen38MTPRev {
			t.Fatalf("artifact metadata = %#v", metadata)
		}
	})

	t.Run("consumer model alias", func(t *testing.T) {
		rec := httptest.NewRecorder()
		srv.handleListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var response types.ModelListResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		model := findQwen38ModelEntry(t, response.Data)
		assertQwen38PublicFields(t, model.ContextLength, model.MaxOutputLength,
			model.InputModalities, model.OutputModalities, model.SupportedFeatures)
		if model.ID != qwen38PublicAlias || model.HuggingFaceID != qwen38ConcreteModel {
			t.Fatalf("alias identity = %+v", model)
		}
		if model.Pricing == nil || model.Pricing.Prompt != "0.00000005" || model.Pricing.Completion != "0.0000002" {
			t.Fatalf("pricing = %+v", model.Pricing)
		}
		for _, item := range response.Data {
			if item.ID == qwen38ConcreteModel {
				t.Fatal("concrete build leaked from the default alias-backed listing")
			}
		}
	})

	t.Run("OpenRouter feed", func(t *testing.T) {
		rec := httptest.NewRecorder()
		srv.handleListModelsOpenRouter(rec, httptest.NewRequest(
			http.MethodGet, "/v1/models/openrouter", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var response types.OpenRouterModelsResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		var model *types.OpenRouterModel
		for i := range response.Data {
			if response.Data[i].ID == qwen38PublicAlias {
				model = &response.Data[i]
				break
			}
		}
		if model == nil {
			t.Fatalf("Qwen3.8 alias absent: %s", rec.Body.String())
		}
		assertQwen38PublicFields(t, model.ContextLength, model.MaxOutputLength,
			model.InputModalities, model.OutputModalities, model.SupportedFeatures)
		if !model.IsReady || model.OpenRouter == nil || model.OpenRouter.Slug != qwen38PublicAlias {
			t.Fatalf("OpenRouter readiness/slug = %+v", model)
		}
	})

	t.Run("live capacity", func(t *testing.T) {
		rec := httptest.NewRecorder()
		srv.handleModelsCapacity(rec, httptest.NewRequest(
			http.MethodGet, "/v1/models/capacity", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var response modelsCapacityResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		for _, model := range response.Models {
			if model.ModelID == qwen38ConcreteModel {
				if model.RoutableProviders < 1 {
					t.Fatalf("capacity = %+v", model)
				}
				return
			}
		}
		t.Fatalf("Qwen3.8 capacity absent: %+v", response.Models)
	})
}

func findQwen38ModelEntry(t *testing.T, entries []types.ModelEntry) types.ModelEntry {
	t.Helper()
	for _, entry := range entries {
		if entry.ID == qwen38PublicAlias {
			return entry
		}
	}
	t.Fatalf("Qwen3.8 alias absent: %+v", entries)
	return types.ModelEntry{}
}

func assertQwen38PublicFields(
	t *testing.T,
	contextLength, maxOutputLength int,
	inputModalities, outputModalities, features []string,
) {
	t.Helper()
	if contextLength != 262144 || maxOutputLength != 32768 {
		t.Fatalf("context/output = %d/%d", contextLength, maxOutputLength)
	}
	if !reflect.DeepEqual(inputModalities, []string{"text", "image", "video"}) ||
		!reflect.DeepEqual(outputModalities, []string{"text"}) {
		t.Fatalf("modalities = %v -> %v", inputModalities, outputModalities)
	}
	if !reflect.DeepEqual(features, []string{"json_mode", "reasoning", "tools"}) {
		t.Fatalf("features = %v", features)
	}
}
