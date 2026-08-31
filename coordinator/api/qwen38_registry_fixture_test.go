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
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	qwen38ConcreteModel     = registry.Qwen38NAXModelID
	qwen38CallableAlias     = "qwen3.8-27b"
	qwen38OpenRouterSlug    = "qwen/qwen3.8-27b"
	qwen38TargetRev         = "301e9e2767fd0efcfab7883004720ba3c9a552a1"
	qwen38MTPModel          = "EigenLabs/Qwen3.8-27B-MTP-4bit"
	qwen38MTPRev            = "329261c5e0b3f9c233485e682cb3b67b88c20a55"
	qwen38TestSpecDecPrefix = "test-fixtures/spec-dec/qwen3.8-27b-mtp-4bit/r1"
	qwen38TestManifestHash  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	qwen38TestConfigHash    = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
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
		RequiredProviderCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
		Status:      "active",
		Description: "Dense Qwen3.8 vision-language model with bounded image and video input.",
		RuntimeParameters: map[string]any{
			"reasoning_parser":       "qwen3",
			"tool_call_parser":       "qwen3_coder",
			"chat_template_required": true,
		},
		Metadata: map[string]any{
			huggingFaceIDMetadataKey: qwen38ConcreteModel,
			"source_revision":        qwen38TargetRev,
			// These deterministic values describe this test fixture only. The
			// production spec-dec payload remains approval-gated and must use
			// the reviewed R2 manifest/config digests and sizes.
			"spec_dec": map[string]any{
				"assistant_model_id": qwen38MTPModel,
				"r2_prefix":          qwen38TestSpecDecPrefix,
				"manifest_sha256":    qwen38TestManifestHash,
				"total_size_bytes":   int64(536_870_912),
				"file_count":         2,
				"max_file_count":     2,
				"allowed_file_types": []string{"config", "weight"},
				"config_sha256":      qwen38TestConfigHash,
				"revision":           qwen38MTPRev,
			},
			"runtime_compatibility": "provider>=0.8.15",
			"openrouter_slug":       qwen38OpenRouterSlug,
			"openrouter_is_ready":   true,
		},
		CreatedAt: time.Date(2026, 8, 24, 0, 0, 0, 0, time.UTC),
	}
}

func TestModelRuntimeDefaults(t *testing.T) {
	desired := qwen38RegistryFixture().RuntimeParameters

	t.Run("fills allowlisted parser defaults only", func(t *testing.T) {
		parsed := map[string]any{"model": qwen38ConcreteModel}
		defaults := newModelRuntimeDefaults(parsed)
		if !defaults.apply(parsed, desired) {
			t.Fatal("expected request defaults to change the body")
		}
		if parsed["reasoning_parser"] != "qwen3" || parsed["tool_call_parser"] != "qwen3_coder" {
			t.Fatalf("parser defaults = %#v", parsed)
		}
		if _, leaked := parsed["chat_template_required"]; leaked {
			t.Fatal("provider/catalog-only runtime parameter leaked into request body")
		}
	})

	t.Run("recomputes same different absent and retry defaults", func(t *testing.T) {
		parsed := map[string]any{"model": "alias"}
		defaults := newModelRuntimeDefaults(parsed)
		if !defaults.apply(parsed, desired) {
			t.Fatal("desired defaults were not injected")
		}

		same := map[string]any{
			"reasoning_parser": "qwen3",
			"tool_call_parser": "qwen3_coder",
		}
		if defaults.apply(parsed, same) {
			t.Fatalf("same defaults unexpectedly changed request: %#v", parsed)
		}

		different := map[string]any{
			"reasoning_parser": "deepseek_r1",
			"tool_call_parser": "hermes",
			"server_only":      "must-not-leak",
		}
		if !defaults.apply(parsed, different) {
			t.Fatal("different fallback defaults were not applied")
		}
		if parsed["reasoning_parser"] != "deepseek_r1" || parsed["tool_call_parser"] != "hermes" {
			t.Fatalf("fallback defaults = %#v", parsed)
		}
		if _, leaked := parsed["server_only"]; leaked {
			t.Fatal("arbitrary runtime parameter leaked into request body")
		}

		if !defaults.apply(parsed, nil) {
			t.Fatal("absent fallback defaults did not remove injected values")
		}
		if _, exists := parsed["reasoning_parser"]; exists {
			t.Fatalf("reasoning_parser survived absent defaults: %#v", parsed)
		}
		if _, exists := parsed["tool_call_parser"]; exists {
			t.Fatalf("tool_call_parser survived absent defaults: %#v", parsed)
		}

		if !defaults.apply(parsed, desired) {
			t.Fatal("retrying desired build did not recompute defaults")
		}
		if parsed["reasoning_parser"] != "qwen3" || parsed["tool_call_parser"] != "qwen3_coder" {
			t.Fatalf("retried desired defaults = %#v", parsed)
		}
	})

	t.Run("explicit consumer values win across concrete models", func(t *testing.T) {
		parsed := map[string]any{
			"reasoning_parser": "deepseek_r1",
			"tool_call_parser": "qwen_xml",
		}
		defaults := newModelRuntimeDefaults(parsed)
		for _, runtimeParameters := range []map[string]any{
			desired,
			{"reasoning_parser": "other_reasoning", "tool_call_parser": "other_tools"},
			nil,
		} {
			if defaults.apply(parsed, runtimeParameters) {
				t.Fatalf("explicit request values changed for %#v", runtimeParameters)
			}
		}
		if parsed["reasoning_parser"] != "deepseek_r1" || parsed["tool_call_parser"] != "qwen_xml" {
			t.Fatalf("explicit values changed: %#v", parsed)
		}
	})

	t.Run("malformed metadata is ignored", func(t *testing.T) {
		parsed := map[string]any{}
		defaults := newModelRuntimeDefaults(parsed)
		if defaults.apply(parsed, map[string]any{
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
		AliasID: qwen38CallableAlias, DisplayName: entry.DisplayName,
		DesiredBuild: qwen38ConcreteModel, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	build, isAlias, ok := reg.ResolveModel(qwen38CallableAlias)
	if !ok || !isAlias || build != qwen38ConcreteModel {
		t.Fatalf("alias resolution = %q isAlias=%v ok=%v", build, isAlias, ok)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn := connectAndPrepareProvider(
		t, ctx, ts.URL, reg, qwen38ConcreteModel, testPublicKeyB64(), 18.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// The generic WebSocket helper intentionally does not manufacture runtime
	// attestation. This fixture exercises the post-verification capacity surface,
	// so advance the connected M5+NAX provider through the same verified state
	// that the attestation/runtime handlers establish in production.
	providerIDs := reg.ProviderIDs()
	if len(providerIDs) != 1 {
		t.Fatalf("connected providers = %v, want one", providerIDs)
	}
	provider := reg.GetProvider(providerIDs[0])
	if provider == nil {
		t.Fatal("connected provider missing from registry")
	}
	signedCapabilities := []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid:                  true,
		ChipFamily:             "M5",
		ChipName:               "Apple M5 Max",
		MetallibHash:           testHash,
		RuntimeCapabilities:    signedCapabilities,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	})
	provider.Mu().Lock()
	if provider.Hardware.ChipFamily != "M5" ||
		!reflect.DeepEqual(provider.ReportedRuntimeCapabilities, signedCapabilities) {
		hardware, capabilities := provider.Hardware, provider.ReportedRuntimeCapabilities
		provider.Mu().Unlock()
		t.Fatalf("fixture provider did not report M5+NAX: hardware=%+v capabilities=%v",
			hardware, capabilities)
	}
	provider.TrustLevel = registry.TrustHardware
	provider.Attested = true
	provider.CodeAttested = true
	provider.FreshCodeAttested = true
	provider.RuntimeManifestChecked = true
	provider.RuntimeVerified = true
	provider.MetallibVerified = true
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatalf("reconcile signed runtime capabilities: %v", err)
	}
	provider.Mu().Lock()
	effectiveCapabilities := append([]string(nil), provider.RuntimeCapabilities...)
	provider.Mu().Unlock()
	if !reflect.DeepEqual(effectiveCapabilities, signedCapabilities) {
		t.Fatalf("effective runtime capabilities = %v, want %v",
			effectiveCapabilities, signedCapabilities)
	}

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
		if metadata["source_revision"] != qwen38TargetRev {
			t.Fatalf("target artifact metadata = %#v", metadata)
		}
		if _, exists := metadata["mtp_artifact_id"]; exists {
			t.Fatalf("flat mtp_artifact_id must not survive: %#v", metadata)
		}
		if _, exists := metadata["mtp_source_revision"]; exists {
			t.Fatalf("flat mtp_source_revision must not survive: %#v", metadata)
		}
		specDec, ok := metadata["spec_dec"].(map[string]any)
		if !ok || specDec["assistant_model_id"] != qwen38MTPModel ||
			specDec["r2_prefix"] != qwen38TestSpecDecPrefix ||
			specDec["manifest_sha256"] != qwen38TestManifestHash ||
			specDec["config_sha256"] != qwen38TestConfigHash ||
			specDec["total_size_bytes"] != float64(536_870_912) || specDec["file_count"] != float64(2) ||
			specDec["max_file_count"] != float64(2) || specDec["revision"] != qwen38MTPRev ||
			!reflect.DeepEqual(specDec["allowed_file_types"], []any{"config", "weight"}) {
			t.Fatalf("test-only spec_dec metadata = %#v", metadata["spec_dec"])
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
		if model.ID != qwen38CallableAlias || model.HuggingFaceID != qwen38ConcreteModel {
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
			if response.Data[i].ID == qwen38CallableAlias {
				model = &response.Data[i]
				break
			}
		}
		if model == nil {
			t.Fatalf("Qwen3.8 alias absent: %s", rec.Body.String())
		}
		assertQwen38PublicFields(t, model.ContextLength, model.MaxOutputLength,
			model.InputModalities, model.OutputModalities, model.SupportedFeatures)
		if !model.IsReady || model.OpenRouter == nil || model.OpenRouter.Slug != qwen38OpenRouterSlug {
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
		if entry.ID == qwen38CallableAlias {
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
