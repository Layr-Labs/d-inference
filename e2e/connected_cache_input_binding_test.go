package e2e

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// catalogModelFromRegistryRecord produces a public API projection, not a
// store.ModelRegistryEntry. Preserve these ignored fields in provenance only;
// model-version identity remains in the unchanged CatalogModel.Manifest.
var publicCatalogOnlyFields = map[string]bool{
	"active": true, "aggregate_sha256": true, "created": true, "file_count": true,
	"hugging_face_id": true, "input_modalities": true, "model_type": true, "name": true,
	"output_modalities": true, "r2_prefix": true, "s3_name": true, "size_gb": true,
	"supported_features": true, "supported_sampling_parameters": true, "total_size_bytes": true,
	"version": true, "weight_hash": true,
}

func canonicalConnectedInput(raw []byte) ([]byte, []map[string]any, error) {
	var input connectedCacheInput
	if err := json.Unmarshal(raw, &input); err != nil {
		return nil, nil, err
	}
	canonical, err := json.MarshalIndent(input, "", "  ")
	if err != nil {
		return nil, nil, err
	}
	var before, after map[string]any
	if err = json.Unmarshal(raw, &before); err != nil {
		return nil, nil, err
	}
	if err = json.Unmarshal(canonical, &after); err != nil {
		return nil, nil, err
	}
	rawCatalog, ok := before["catalog"].([]any)
	if !ok || len(rawCatalog) != len(input.Catalog) {
		return nil, nil, fmt.Errorf("exact catalog array required")
	}
	consumedCatalog := after["catalog"].([]any)
	notes := []map[string]any{}
	for index, model := range input.Catalog {
		original := rawCatalog[index].(map[string]any)
		consumed := consumedCatalog[index].(map[string]any)
		originalEntry, ok := original["Entry"].(map[string]any)
		if !ok {
			return nil, nil, fmt.Errorf("catalog Entry object required")
		}
		entry := consumed["Entry"].(map[string]any)
		ignored := []string{}
		for key, value := range originalEntry {
			if actual, present := entry[key]; present {
				if !reflect.DeepEqual(value, actual) {
					return nil, nil, fmt.Errorf("consumed catalog policy field changed: %s", key)
				}
			} else {
				if !publicCatalogOnlyFields[key] {
					return nil, nil, fmt.Errorf("unrecognized catalog Entry field: %s", key)
				}
				ignored = append(ignored, key)
			}
		}
		for key := range entry {
			if _, present := originalEntry[key]; !present && key != "created_at" && key != "updated_at" {
				return nil, nil, fmt.Errorf("missing explicit consumed catalog field: %s", key)
			}
		}
		if model.Entry.ID == "" || model.Manifest.ModelID != model.Entry.ID {
			return nil, nil, fmt.Errorf("catalog model identity differs")
		}
		mirrors := map[string]any{"active": model.Entry.Status == "active" || model.Entry.Status == "beta", "name": model.Entry.DisplayName,
			"aggregate_sha256": model.Manifest.AggregateSHA256, "weight_hash": model.Manifest.AggregateSHA256, "version": model.Manifest.Version,
			"r2_prefix": model.Manifest.R2Prefix, "s3_name": model.Manifest.R2Prefix, "file_count": float64(model.Manifest.FileCount),
			"total_size_bytes": float64(model.Manifest.TotalSizeBytes), "size_gb": float64(model.Manifest.TotalSizeBytes) / 1e9}
		for key, expected := range mirrors {
			if value, present := originalEntry[key]; present && !reflect.DeepEqual(value, expected) {
				return nil, nil, fmt.Errorf("public catalog/manifest mirror differs: %s", key)
			}
		}
		sort.Strings(ignored)
		notes = append(notes, map[string]any{"model_id": model.Entry.ID, "ignored_public_fields": ignored, "raw_entry": originalEntry, "consumed_entry": entry, "manifest_unchanged": reflect.DeepEqual(original["Manifest"], consumed["Manifest"])})
		original["Entry"] = entry
	}
	if !reflect.DeepEqual(before, after) {
		return nil, nil, fmt.Errorf("full input changed outside the explicitly projected catalog Entry")
	}
	// The exact report uses this type, so this catches its normalization too.
	reportRaw, err := json.Marshal(connectedReport{Input: input})
	if err != nil {
		return nil, nil, err
	}
	var report map[string]any
	if err = json.Unmarshal(reportRaw, &report); err != nil {
		return nil, nil, err
	}
	if !reflect.DeepEqual(report["input"], after) {
		return nil, nil, fmt.Errorf("actual report.Input roundtrip differs")
	}
	var second connectedCacheInput
	decoder := json.NewDecoder(bytes.NewReader(canonical))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&second); err != nil {
		return nil, nil, err
	}
	if !reflect.DeepEqual(input, second) {
		return nil, nil, fmt.Errorf("typed full input roundtrip differs")
	}
	return append(canonical, '\n'), notes, nil
}

func TestConnectedInputCatalogProjectionPreservesPolicyAndManifest(t *testing.T) {
	input := connectedCacheInput{Catalog: []testbed.CatalogModel{{Entry: store.ModelRegistryEntry{ID: "gpt-oss-20b", DisplayName: "GPT-OSS 20B", Status: "active", MaxContextLength: 131072, MaxOutputLength: 32768, MinRAMGB: 24, Capabilities: []string{"chat"}, RequiredProviderCapabilities: []string{}, RuntimeParameters: map[string]any{}, Metadata: map[string]any{}}, Manifest: store.ModelManifest{ModelID: "gpt-oss-20b", Version: "v1", AggregateSHA256: "hash", R2Prefix: "prefix", FileCount: 0, TotalSizeBytes: 0}}}, Prompt: "unchanged prompt", ToolsRequest: json.RawMessage("null")}
	raw, err := json.Marshal(input)
	require.NoError(t, err)
	var value map[string]any
	require.NoError(t, json.Unmarshal(raw, &value))
	entry := value["catalog"].([]any)[0].(map[string]any)["Entry"].(map[string]any)
	delete(entry, "created_at")
	delete(entry, "updated_at")
	entry["active"] = true
	entry["weight_hash"] = "hash"
	entry["created"] = float64(1779749187)
	raw, err = json.Marshal(value)
	require.NoError(t, err)
	canonical, notes, err := canonicalConnectedInput(raw)
	require.NoError(t, err)
	var actual connectedCacheInput
	require.NoError(t, json.Unmarshal(canonical, &actual))
	require.Equal(t, input, actual)
	require.Equal(t, []string{"active", "created", "weight_hash"}, notes[0]["ignored_public_fields"])
	entry["unreviewed_policy_override"] = true
	raw, err = json.Marshal(value)
	require.NoError(t, err)
	_, _, err = canonicalConnectedInput(raw)
	require.ErrorContains(t, err, "unrecognized catalog Entry field")
	delete(entry, "unreviewed_policy_override")
	entry["weight_hash"] = "different"
	raw, err = json.Marshal(value)
	require.NoError(t, err)
	_, _, err = canonicalConnectedInput(raw)
	require.ErrorContains(t, err, "mirror differs")
}

// Opt-in CPU preparation only: no Suite, host check, sidecar or model is started.
func TestPrepareConnectedInputBindings(t *testing.T) {
	planPath := os.Getenv("DARKBLOOM_CONNECTED_INPUT_BINDING_PLAN")
	if planPath == "" {
		t.Skip("explicit CPU-only input binding plan required")
	}
	var plan struct {
		OutputDirectory string                        `json:"output_directory"`
		Inputs          []struct{ Mode, Path string } `json:"inputs"`
	}
	raw, err := os.ReadFile(planPath)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(raw, &plan))
	require.True(t, filepath.IsAbs(plan.OutputDirectory))
	require.Len(t, plan.Inputs, 2)
	require.NoError(t, os.Mkdir(plan.OutputDirectory, 0700), "fresh output directory required")
	results := []map[string]any{}
	for index, row := range plan.Inputs {
		require.Equal(t, []string{"off", "ssd"}[index], row.Mode)
		original, err := os.ReadFile(row.Path)
		require.NoError(t, err)
		canonical, notes, err := canonicalConnectedInput(original)
		require.NoError(t, err)
		var input connectedCacheInput
		require.NoError(t, json.Unmarshal(canonical, &input))
		require.NoError(t, validateConnectedRunScope(input, true))
		require.NoError(t, validateConnectedTargetBindings(input))
		require.Equal(t, row.Mode, input.CacheMode)
		output := filepath.Join(plan.OutputDirectory, row.Mode+".input.json")
		require.NoError(t, os.WriteFile(output, canonical, 0600))
		require.NoError(t, os.WriteFile(filepath.Join(plan.OutputDirectory, row.Mode+".original.json"), original, 0600))
		before, after := sha256.Sum256(original), sha256.Sum256(canonical)
		results = append(results, map[string]any{"mode": row.Mode, "input_path": row.Path, "original_sha256": hex.EncodeToString(before[:]), "canonical_path": output, "canonical_sha256": hex.EncodeToString(after[:]), "actual_input_type": "connectedCacheInput", "actual_report_type": "connectedReport.Input", "full_roundtrip_exact": true, "target_bindings_valid": true, "catalog": notes})
	}
	proof, err := json.MarshalIndent(map[string]any{"results": results, "host_or_model_calls": false}, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(plan.OutputDirectory, "roundtrip-proof.json"), append(proof, '\n'), 0600))
}
