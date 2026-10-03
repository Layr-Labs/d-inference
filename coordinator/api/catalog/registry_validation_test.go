package catalog

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/modelprice"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestValidateModelManifestRejectsTraversalAndBadHashes(t *testing.T) {
	prefix := modelR2Prefix("mlx-community/test", "v1")
	manifest := validTestManifest()
	manifest.Files[0].Path = "weights/../config.json"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected traversal path to be rejected")
	}

	manifest = validTestManifest()
	manifest.AggregateSHA256 = "ABC"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected bad aggregate hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.AggregateSHA256 = testHash
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected mismatched aggregate hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files[0].SHA256 = "bbbb"
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected bad file hash to be rejected")
	}

	manifest = validTestManifest()
	manifest.TotalSizeBytes = 999
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected mismatched total_size_bytes to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files = nil
	manifest.FileCount = 0
	manifest.TotalSizeBytes = 0
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected empty manifest to be rejected")
	}

	manifest = validTestManifest()
	manifest.Files = append(manifest.Files, manifest.Files[0])
	manifest.FileCount = 2
	manifest.TotalSizeBytes = 246
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected duplicate manifest paths to be rejected")
	}

	manifest = validTestManifest()
	caseCollidingFile := manifest.Files[0]
	caseCollidingFile.Path = "Config.json"
	manifest.Files = append(manifest.Files, caseCollidingFile)
	manifest.FileCount = 2
	manifest.TotalSizeBytes = 246
	if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
		t.Fatal("expected case-colliding manifest paths to be rejected")
	}

	for _, badPath := range []string{"a//b", "./x", "x/.", "x/../y"} {
		manifest = validTestManifest()
		manifest.Files[0].Path = badPath
		if err := validateModelManifest(manifest, "mlx-community/test", "v1", prefix); err == nil {
			t.Fatalf("expected path %q to be rejected", badPath)
		}
	}
}

func TestRegisterValidationAndR2Prefix(t *testing.T) {
	for _, req := range []registerModelRequest{
		{ModelID: "bad id", Version: "v1"},
		{ModelID: "../bad", Version: "v1"},
		{ModelID: "ok/model", Version: "bad/version"},
		{ModelID: "ok/model", Version: "bad..version"},
		{ModelID: "ok/model", Version: "v1", Quantization: "", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 0, MaxOutputLength: 1, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 0, MinRAMGB: 1},
		{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 0},
	} {
		if err := validateRegisterModelRequest(req); err == nil {
			t.Fatalf("expected invalid request to fail: %#v", req)
		}
	}
	// Verify missing pricing is rejected.
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, Input: modelprice.Input{InputPrice: 0, OutputPrice: 100}}); err == nil {
		t.Fatal("expected missing input_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, Input: modelprice.Input{InputPrice: 100, OutputPrice: 0}}); err == nil {
		t.Fatal("expected missing output_price to fail")
	}
	// A cache-read rate above the input rate is a misconfiguration, not a price.
	overInput := int64(101)
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, Input: modelprice.Input{InputPrice: 100, OutputPrice: 100, CacheReadPrice: &overInput}}); err == nil {
		t.Fatal("expected cache_read_price above input_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "mlx-community/gemma-4-26b-a4b-it-8bit", Version: "2026-05-23-r1", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 36, Input: modelprice.Input{InputPrice: 30000, OutputPrice: 165000}}); err != nil {
		t.Fatalf("expected valid request: %v", err)
	}
	if modelR2Prefix("foo/bar", "v1") == modelR2Prefix("foo__bar", "v1") {
		t.Fatal("modelR2Prefix must not collide for slash vs underscore model IDs")
	}
	if got := modelR2Prefix("mlx-community/openai-gpt-oss-20b", "2026-05-23-r1"); got != "v2/mlx-community-openai-gpt-oss-20b--8f458c9d97d4/2026-05-23-r1" {
		t.Fatalf("unexpected human-readable R2 prefix: %s", got)
	}
	if got := modelR2Prefix("foo/bar", "v1"); got != "v2/foo-bar--cc5d46bdb499/v1" {
		t.Fatalf("unexpected slash slug prefix: %s", got)
	}
	if got := modelR2Prefix("foo__bar", "v1"); got != "v2/foo__bar--a3a759156e88/v1" {
		t.Fatalf("unexpected underscore slug prefix: %s", got)
	}
}

func TestCatalogAliasesForResponse(t *testing.T) {
	models := []map[string]any{
		{"id": "gemma-4-26b-qat-4bit"},
		{"id": "gemma-4-26b"},
	}
	aliases := []store.ModelAlias{
		{
			AliasID:       "gemma-4-26b",
			DisplayName:   "Gemma 4 26B",
			DesiredBuild:  "gemma-4-26b-qat-4bit",
			PreviousBuild: "gemma-4-26b",
			RetiredBuilds: []string{"gemma-4-26b-old"},
			Active:        true,
		},
		{AliasID: "inactive", DesiredBuild: "missing", Active: false},
	}

	got := catalogAliasesForResponse(models, aliases)
	if len(got) != 1 {
		t.Fatalf("alias count = %d, want 1", len(got))
	}
	alias := got[0]
	if alias["id"] != "gemma-4-26b" || alias["display_name"] != "Gemma 4 26B" {
		t.Fatalf("unexpected alias identity: %#v", alias)
	}
	if alias["desired_build"] != "gemma-4-26b-qat-4bit" || alias["previous_build"] != "gemma-4-26b" {
		t.Fatalf("unexpected alias builds: %#v", alias)
	}
	if alias["primary_build"] != "gemma-4-26b-qat-4bit" {
		t.Fatalf("primary_build = %v, want desired", alias["primary_build"])
	}
	retired, ok := alias["retired_builds"].([]string)
	if !ok || len(retired) != 1 || retired[0] != "gemma-4-26b-old" {
		t.Fatalf("retired_builds = %#v", alias["retired_builds"])
	}
}

func TestParseModelCatalogPathsDisambiguatesManifestSuffix(t *testing.T) {
	modelID, ok := parseModelCatalogPath("/v1/models/catalog/org/manifest")
	if !ok || modelID != "org/manifest" {
		t.Fatalf("expected catalog item path to preserve /manifest model id, got %q ok=%v", modelID, ok)
	}
	manifestID, ok := parseModelCatalogManifestPath("/v1/models/catalog/manifest/org%2Fmanifest")
	if !ok || manifestID != "org/manifest" {
		t.Fatalf("expected manifest route to decode model id, got %q ok=%v", manifestID, ok)
	}
}

func TestModelRegistryNotFoundClassification(t *testing.T) {
	if !isModelRegistryNotFound(fmt.Errorf("model %q not found", "x")) {
		t.Fatal("expected not found error to classify as not found")
	}
	if isModelRegistryNotFound(fmt.Errorf("store: get model registry record: connection refused")) {
		t.Fatal("expected DB error not to classify as not found")
	}
}

func validTestManifest() *store.ModelManifest {
	files := []store.ManifestFile{{
		Path:      "config.json",
		SizeBytes: 123,
		SHA256:    testHash,
		Role:      "config",
	}}
	return &store.ModelManifest{
		SchemaVersion:   1,
		ModelID:         "mlx-community/test",
		Version:         "v1",
		R2Prefix:        modelR2Prefix("mlx-community/test", "v1"),
		AggregateSHA256: aggregateManifestFileHashes(files),
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
	}
}
