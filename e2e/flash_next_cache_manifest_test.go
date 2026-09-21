package e2e

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/stretchr/testify/require"
)

// CPU-only opt-in: validate provisioning before paying for a model reload.
// Reads selected prompt metadata and weight file sizes, never launches MLX.
func TestFlashNextCacheManifestProvisioning(t *testing.T) {
	if os.Getenv("DARKBLOOM_FLASH_NEXT_CACHE_MANIFEST_CHECK") != "1" {
		t.Skip("explicit selected artifact metadata required; no GPU is used")
	}
	fixture := flashNextCacheArtifacts(t)
	fixture.manifest.R2Prefix = "artifacts"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		body, ok := fixture.files[strings.TrimPrefix(request.URL.Path, "/artifacts/")]
		if !ok {
			http.NotFound(w, request)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(server.Close)
	base, err := url.Parse(server.URL)
	require.NoError(t, err)
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root: filepath.Join(exactCacheTempRoot(t), "contracts"), BaseURL: base, AllowHTTP: true,
	})
	require.NoError(t, err)
	prompts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	negative := fixture.manifest
	negative.Files = prompts
	_, err = cache.Ensure(context.Background(), negative)
	require.ErrorIs(t, err, promptcontract.ErrArtifactIntegrity,
		"a prompt-only manifest must not impersonate the full model aggregate")
	actual, err := cache.Ensure(context.Background(), fixture.manifest)
	require.NoError(t, err)
	expected, err := promptcontract.ContractID(prompts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	require.Equal(t, expected, filepath.Base(actual))
	raw, err := os.ReadFile(filepath.Join(actual, promptcontract.MetadataFile))
	require.NoError(t, err)
	var metadata promptcontract.Metadata
	require.NoError(t, json.Unmarshal(raw, &metadata))
	require.Equal(t, expected, metadata.PromptContractID)
	require.Equal(t, fixture.manifest.AggregateSHA256, metadata.ModelAggregateSHA256)
}
