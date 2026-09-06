package e2e

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func connectedHostInputFixture() connectedCacheInput {
	file := testbed.ProviderFile{SHA256: strings.Repeat("a", 64), Bytes: 3, Mode: 0644}
	binary := file
	binary.Mode = 0755
	in := connectedCacheInput{ProviderSHA256: file.SHA256, MetallibSHA256: file.SHA256,
		Artifact: registry.CacheRoutingArtifact{ModelID: "target"}, AssistantPath: "/local/assistant"}
	for _, id := range []string{"target", "assistant"} {
		in.Catalog = append(in.Catalog, testbed.CatalogModel{
			Entry: store.ModelRegistryEntry{ID: id},
			Manifest: store.ModelManifest{ModelID: id, Files: []store.ManifestFile{
				{Path: "weights", SizeBytes: file.Bytes, SHA256: file.SHA256},
			}},
		})
	}
	for _, name := range []string{"host_a", "host_b"} {
		in.Providers = append(in.Providers, testbed.ProviderTarget{
			Name: name, Root: "/owned/" + name, RuntimeDirectory: "/runtime",
			RuntimeFiles: map[string]testbed.ProviderFile{"darkbloom": binary, "mlx.metallib": file, "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal": file},
			Models: []testbed.ProviderModelInput{
				{ID: "target", Snapshot: "/models/target", Files: map[string]testbed.ProviderFile{"weights": file}},
				{ID: "assistant", Snapshot: "/models/assistant", Files: map[string]testbed.ProviderFile{"weights": file}},
			},
			AssistantPath: "/models/assistant", CanonicalConfigSHA256: file.SHA256,
			HardwareModel: "MacFixture,1", MemoryBytes: 36 << 30, MacmonPath: "/macmon", Macmon: binary,
		})
	}
	return in
}

func TestConnectedHostsBindExactRuntimeTargetAndAssistantBeforeIO(t *testing.T) {
	require.NoError(t, validateConnectedTargetBindings(connectedHostInputFixture()))
	for name, fault := range map[string]func(*connectedCacheInput){
		"runtime": func(in *connectedCacheInput) {
			row := in.Providers[1].RuntimeFiles["darkbloom"]
			row.SHA256 = strings.Repeat("b", 64)
			in.Providers[1].RuntimeFiles["darkbloom"] = row
		},
		"bundle_source": func(in *connectedCacheInput) {
			name := "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
			row := in.Providers[1].RuntimeFiles[name]
			row.SHA256 = strings.Repeat("b", 64)
			in.Providers[1].RuntimeFiles[name] = row
		},
		"bundle_mode": func(in *connectedCacheInput) {
			name := "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
			row := in.Providers[1].RuntimeFiles[name]
			row.Mode = 0600
			in.Providers[1].RuntimeFiles[name] = row
		},
		"bundle_missing": func(in *connectedCacheInput) {
			delete(in.Providers[1].RuntimeFiles, "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal")
		},
		"bundle_size": func(in *connectedCacheInput) {
			name := "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
			row := in.Providers[1].RuntimeFiles[name]
			row.Bytes++
			in.Providers[1].RuntimeFiles[name] = row
		},
		"assistant_bytes": func(in *connectedCacheInput) {
			row := in.Providers[1].Models[1].Files["weights"]
			row.SHA256 = strings.Repeat("b", 64)
			in.Providers[1].Models[1].Files["weights"] = row
		},
		"assistant_size": func(in *connectedCacheInput) {
			row := in.Providers[1].Models[1].Files["weights"]
			row.Bytes++
			in.Providers[1].Models[1].Files["weights"] = row
		},
		"unpinned_assistant":  func(in *connectedCacheInput) { in.Providers[1].AssistantPath = "/other" },
		"target_as_assistant": func(in *connectedCacheInput) { in.Providers[1].AssistantPath = "/models/target" },
		"missing_model":       func(in *connectedCacheInput) { in.Providers[1].Models = in.Providers[1].Models[:1] },
		"extra_file": func(in *connectedCacheInput) {
			in.Providers[1].Models[0].Files["extra"] = in.Providers[1].Models[0].Files["weights"]
		},
	} {
		t.Run(name, func(t *testing.T) {
			in := connectedHostInputFixture()
			fault(&in)
			require.Error(t, validateConnectedTargetBindings(in))
			_, err := in.validate()
			require.Error(t, err)
			require.NotContains(t, err.Error(), "no such file", "refusal must precede local model reads")
		})
	}
}
