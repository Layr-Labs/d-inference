package e2e

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// The two tests in this file run first sight on, through the real coordinator
// and one real provider. Every other exact-cache e2e test leaves
// FirstSightMinTokens at 0 and so runs first sight off.
//
// Both put the wire relay between the two: it records the two demand counts
// of every inference_request as the coordinator sent them, and in the
// mixed-version test it removes cache_first_sight_tokens so the provider sees
// what a provider build without the field would act on.
//
// Gated: both run only with DARKBLOOM_EXACT_CACHE_FIRST_SIGHT_E2E=1. Each
// loads the exact-cache test model in its own suite and prefills a long prompt
// two or three times, which the blocking integration lane (every
// TestIntegration test in one 25-minute step) has no time budgeted for.

const firstSightWireField = "cache_first_sight_tokens"

func skipUnlessFirstSightE2E(t *testing.T) {
	t.Helper()
	if testing.Short() {
		t.Skip("requires the real Swift provider and local MLX checkpoint")
	}
	if os.Getenv("DARKBLOOM_EXACT_CACHE_FIRST_SIGHT_E2E") != "1" {
		t.Skip("set DARKBLOOM_EXACT_CACHE_FIRST_SIGHT_E2E=1 to run the first-sight cases")
	}
}

// TestIntegrationExactCacheFirstSightWritesSpeculatively joins the three links
// the unit tests cover one at a time: the coordinator sends a novel prompt's
// depth in cache_first_sight_tokens beside a repeat count of 0, the provider
// classes the request's checkpoints as speculative rather than novel, and what
// it did with them reaches the coordinator's donation outcomes.
//
// It takes the loader's default for FirstSightMinTokens rather than naming a
// number, so it also runs what an unconfigured coordinator runs.
func TestIntegrationExactCacheFirstSightWritesSpeculatively(t *testing.T) {
	skipUnlessFirstSightE2E(t)
	t.Setenv("EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS", "")
	firstSightMinTokens := registry.ReadConfig().CacheRouting.FirstSightMinTokens
	require.Equal(t, 1024, firstSightMinTokens, "the loader default changed")

	relay := &testbed.ProviderWireRelay{}
	suite, model := startFirstSightSuite(t, relay, firstSightMinTokens)
	prompt := longExactCachePrompt()

	before := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	sent := len(inferenceRequestFrames(relay))
	first := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, first.cachedTokens, "a novel prompt must prefill cold")

	frame := requireInferenceRequestFrame(t, relay, sent)
	require.Equal(t, 0, requireFrameCount(t, frame, "cache_repeated_prefix_tokens"),
		"first sight must not raise the repeat count")
	depth := requireFrameCount(t, frame, firstSightWireField)
	require.GreaterOrEqual(t, depth, firstSightMinTokens)
	require.Zero(t, depth%1024, "first sight names a 1,024-token boundary")
	require.NotContains(t, frame.Fields, "stripped_fields")

	// The provider settles one outcome per offered checkpoint and reports the
	// counts on its heartbeat. A speculative offer is written (donated) or
	// yields (write_speculative_limited). Had the count not reached the store,
	// the request would be fleet-novel and settle skipped_novel instead.
	outcome := func(name string) uint64 {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().DonationOutcomes[name] -
			before.DonationOutcomes[name]
	}
	require.Eventually(t, func() bool {
		return outcome("donated")+outcome("write_speculative_limited") > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"the first-sight request settled neither donated nor write_speculative_limited")
	settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
	require.Zero(t, outcome("skipped_novel"),
		"a first-sight request reached the provider's store as a fleet-novel one")
	t.Logf("first sight at %d tokens: donated %d, write_speculative_limited %d",
		depth, outcome("donated"), outcome("write_speculative_limited"))

	if outcome("donated") == 0 {
		// Write, writer or disk pressure on this host. The policy allows it;
		// there is then no checkpoint for a follow-up to restore.
		t.Log("the speculative write yielded; the follow-up hit is not asserted")
		return
	}
	// What first sight is for: the prompt's second request restores what its
	// first one wrote.
	require.Eventually(t, func() bool {
		holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return holders > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"the speculative checkpoint did not publish a reusable cache holder")
	sent = len(inferenceRequestFrames(relay))
	second := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, second.cachedTokens, "the second request did not reuse the first-sight checkpoint")
	require.Equal(t, first.content, second.content)
	// The second sighting is a proven repeat and carries no first-sight count.
	frame = requireInferenceRequestFrame(t, relay, sent)
	require.GreaterOrEqual(t, requireFrameCount(t, frame, "cache_repeated_prefix_tokens"), 1024)
	require.NotContains(t, frame.Fields, firstSightWireField)
}

// TestIntegrationExactCacheFirstSightMixedVersion pairs a coordinator that
// sends first sight with a provider that never receives the field, which is
// what a provider build without it acts on. The novel prime must behave as
// first sight off for writes (skipped_novel, no holder), and the follow-up,
// now an observed repeat, must write as it always has.
func TestIntegrationExactCacheFirstSightMixedVersion(t *testing.T) {
	skipUnlessFirstSightE2E(t)
	const firstSightMinTokens = 1024
	relay := &testbed.ProviderWireRelay{StripCoordinatorFields: []string{firstSightWireField}}
	suite, model := startFirstSightSuite(t, relay, firstSightMinTokens)
	prompt := longExactCachePrompt()

	before := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	outcome := func(name string) uint64 {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().DonationOutcomes[name] -
			before.DonationOutcomes[name]
	}
	sent := len(inferenceRequestFrames(relay))
	prime := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, prime.cachedTokens, "a novel prompt must prefill cold")

	// The coordinator sent first sight; the relay removed it on the way.
	frame := requireInferenceRequestFrame(t, relay, sent)
	require.Equal(t, 0, requireFrameCount(t, frame, "cache_repeated_prefix_tokens"))
	require.GreaterOrEqual(t, requireFrameCount(t, frame, firstSightWireField), firstSightMinTokens)
	require.JSONEq(t, `["`+firstSightWireField+`"]`, string(frame.Fields["stripped_fields"]))

	require.Eventually(t, func() bool { return outcome("skipped_novel") > 0 },
		30*time.Second, 100*time.Millisecond,
		"without the first-sight count the prime did not settle skipped_novel")
	settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
	require.Zero(t, outcome("donated"), "a provider that never saw first sight wrote a novel checkpoint")
	require.Zero(t, outcome("write_speculative_limited"),
		"a provider that never saw first sight classed an offer as speculative")
	holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
	require.Zero(t, holders, "a novel prime must not publish a holder without first sight")

	// The follow-up is an observed repeat: a repeat count, no first sight, and
	// the write every provider with the demand gate performs.
	sent = len(inferenceRequestFrames(relay))
	donor := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, donor.cachedTokens, "nothing was written for the follow-up to restore")
	require.Equal(t, prime.content, donor.content)
	frame = requireInferenceRequestFrame(t, relay, sent)
	require.GreaterOrEqual(t, requireFrameCount(t, frame, "cache_repeated_prefix_tokens"), 1024)
	require.NotContains(t, frame.Fields, firstSightWireField)
	require.NotContains(t, frame.Fields, "stripped_fields")
	require.Eventually(t, func() bool {
		holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return holders > 0 && outcome("donated") > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"the follow-up's proven checkpoint was not written and published")

	third := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, third.cachedTokens)
	require.Equal(t, prime.content, third.content)
	require.Zero(t, outcome("write_speculative_limited"))
}

// startFirstSightSuite starts one real provider behind the relay, loads the
// exact-cache test model and turns cache routing on with the given first-sight
// minimum.
func startFirstSightSuite(t *testing.T, relay *testbed.ProviderWireRelay, firstSightMinTokens int) (*testbed.Suite, string) {
	t.Helper()
	model := exactCacheRoutingTestModelID()
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs:                 []testbed.ModelSpec{{ModelID: model, NumProviders: 1}},
		NumUsers:                   1,
		EnableEphemeralPrefixCache: true,
		// This development checkpoint is outside the default-on production
		// catalog. Ephemeral keys isolate storage; they do not enable caching.
		PrefixCacheMode: "ssd",
		ProviderRelay:   relay,
	})
	require.NoError(t, suite.Start(context.Background()))
	t.Cleanup(suite.Stop)

	providers := liveProviders(suite.Coordinator.Registry)
	require.Len(t, providers, 1)
	provider := providers[0]
	require.NoError(t, suite.Coordinator.Registry.SendLoadModel(provider.ID, model))
	loaded := waitForLoadedModel(t, provider, model, 3*time.Minute)
	require.Eventually(t, func() bool {
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		_, advertised := provider.PrefixCacheV2Models[model]
		return advertised
	}, 30*time.Second, 100*time.Millisecond,
		"the slot did not advertise exact-cache capability after SSD scan readiness")

	fixture := loadExactCacheArtifacts(t, model, loaded.WeightHash)
	contractArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contractID, err := promptcontract.ContractID(contractArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	startExactCacheSidecar(t, suite, fixture, model, contractID)
	suite.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, WeightHash: loaded.WeightHash,
	}})
	maxDiscountMs, maxCostFraction := 1000.0, .35
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(
		registry.CacheRoutingConfig{
			Mode:                registry.CacheRoutingOn,
			ActivationPct:       100,
			TTL:                 10 * time.Minute,
			MaxHolders:          4,
			MaxDiscountMs:       &maxDiscountMs,
			MaxCostFraction:     &maxCostFraction,
			MasterKey:           "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
			FirstSightMinTokens: firstSightMinTokens,
		}))
	return suite, model
}

// inferenceRequestFrames returns the inference_request frames the coordinator
// has sent so far, in order.
func inferenceRequestFrames(relay *testbed.ProviderWireRelay) []testbed.ProviderWireEvent {
	events, _ := relay.Snapshot()
	var frames []testbed.ProviderWireEvent
	for _, event := range events {
		if event.Direction == "coordinator_to_provider" && event.Type == "inference_request" {
			frames = append(frames, event)
		}
	}
	return frames
}

// requireInferenceRequestFrame returns the first inference_request sent after
// the first `sent` ones: the original dispatch of the request that followed.
func requireInferenceRequestFrame(t *testing.T, relay *testbed.ProviderWireRelay, sent int) testbed.ProviderWireEvent {
	t.Helper()
	frames := inferenceRequestFrames(relay)
	require.Greater(t, len(frames), sent, "the relay recorded no inference_request for this request")
	return frames[sent]
}

func requireFrameCount(t *testing.T, frame testbed.ProviderWireEvent, field string) int {
	t.Helper()
	raw, ok := frame.Fields[field]
	require.True(t, ok, "inference_request carried no %s", field)
	var count int
	require.NoError(t, json.Unmarshal(raw, &count))
	return count
}
