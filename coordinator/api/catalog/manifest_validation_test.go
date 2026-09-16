package catalog

import (
	"testing"
)

func TestValidateModelManifestRejectsTraversalAndBadHashes(t *testing.T) {
	prefix := ModelR2Prefix("mlx-community/test", "v1")
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
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, InputPrice: 0, OutputPrice: 100}); err == nil {
		t.Fatal("expected missing input_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "ok/model", Version: "v1", Quantization: "8bit", MaxContextLength: 1, MaxOutputLength: 1, MinRAMGB: 1, InputPrice: 100, OutputPrice: 0}); err == nil {
		t.Fatal("expected missing output_price to fail")
	}
	if err := validateRegisterModelRequest(registerModelRequest{ModelID: "mlx-community/gemma-4-26b-a4b-it-8bit", Version: "2026-05-23-r1", Quantization: "8bit", MaxContextLength: 32768, MaxOutputLength: 8192, MinRAMGB: 36, InputPrice: 30000, OutputPrice: 165000}); err != nil {
		t.Fatalf("expected valid request: %v", err)
	}
	if ModelR2Prefix("foo/bar", "v1") == ModelR2Prefix("foo__bar", "v1") {
		t.Fatal("modelR2Prefix must not collide for slash vs underscore model IDs")
	}
	if got := ModelR2Prefix("mlx-community/openai-gpt-oss-20b", "2026-05-23-r1"); got != "v2/mlx-community-openai-gpt-oss-20b--8f458c9d97d4/2026-05-23-r1" {
		t.Fatalf("unexpected human-readable R2 prefix: %s", got)
	}
	if got := ModelR2Prefix("foo/bar", "v1"); got != "v2/foo-bar--cc5d46bdb499/v1" {
		t.Fatalf("unexpected slash slug prefix: %s", got)
	}
	if got := ModelR2Prefix("foo__bar", "v1"); got != "v2/foo__bar--a3a759156e88/v1" {
		t.Fatalf("unexpected underscore slug prefix: %s", got)
	}
}
