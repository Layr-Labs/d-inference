package e2e

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// Native source 0df89a114b74826b085817a08a94f4fd5ec859bf is the authority:
// PrefixCachePolicy.isEnabled includes isBonsai2ListingModelID;
// MTPMode.automaticEmbeddedModelTypes excludes prism_hadamard_qwen35.
// This CPU regression only aligns fixture expectations. The existing real
// HTTP smoke must still prove actual SSD adoption and inactive MTP at runtime.
func TestReleaseDefaultBonsaiMatchesNativePolicy(t *testing.T) {
	in := connectedCacheInput{Backend: "auto", MTPMode: "auto", CacheMode: "ssd", MaxConcurrent: 1}
	in.Artifact.ModelID = "ternary-bonsai-2-27b"
	expected, err := releaseDefaultSelection(in)
	require.NoError(t, err)
	require.Equal(t, releaseDefaultExpectation{cache: "ssd", mtp: "off"}, expected)
	cfg := releaseDefaultSuite(in, nil)
	require.Equal(t, 1, cfg.TotalProviders())
	require.Empty(t, cfg.PrefixCacheMode, "the fixture must observe the production cache default")
	require.Equal(t, "auto", cfg.KVBackend)
	require.Equal(t, "paged", cfg.ExpectKVBackend)
	require.Equal(t, "auto", cfg.MTPMode, "inactive MTP must be observed, not forced off")
	require.Equal(t, 1, cfg.MaxConcurrent)
	require.True(t, cfg.EnableEphemeralPrefixCache)
	for _, mutate := range []func(*connectedCacheInput){
		func(x *connectedCacheInput) { x.CacheMode = "off" },
		func(x *connectedCacheInput) { x.CacheMode = "memory" },
		func(x *connectedCacheInput) { x.Backend = "paged" },
		func(x *connectedCacheInput) { x.MTPMode = "off" },
		func(x *connectedCacheInput) { x.MaxConcurrent = 2 },
		func(x *connectedCacheInput) { x.AssistantPath = "/not-an-authorized-assistant" },
		func(x *connectedCacheInput) { x.Artifact.ModelID = "ternary-bonsai-2-27b-other" },
	} {
		changed := in
		mutate(&changed)
		_, err := releaseDefaultSelection(changed)
		require.Error(t, err)
	}
}
