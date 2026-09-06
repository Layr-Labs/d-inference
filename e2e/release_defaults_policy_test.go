package e2e

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

type releaseDefaultExpectation struct{ cache, mtp string }

func releaseDefaultSelection(in connectedCacheInput) (releaseDefaultExpectation, error) {
	expected := releaseDefaultExpectation{cache: "off", mtp: "off"}
	switch in.Artifact.ModelID {
	case "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp":
		expected = releaseDefaultExpectation{cache: "ssd", mtp: "on"}
	case "gpt-oss-20b", "gemma-4-26b-qat-4bit":
	default:
		return expected, fmt.Errorf("exact release target required")
	}
	if in.Backend != "auto" || in.MTPMode != "auto" || in.CacheMode != expected.cache || in.MaxConcurrent != 1 || in.AssistantPath != "" || in.Providers != nil || in.CorrectnessOnly {
		return expected, fmt.Errorf("default smoke requires auto backend/MTP, expected model cache tier, B1, no assistant override and one local owned provider")
	}
	return expected, nil
}

func releaseDefaultEnvironment(environment []string) error {
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		for _, prefix := range []string{"DARKBLOOM_PREFIX_CACHE", "DARKBLOOM_CBV2_", "DARKBLOOM_MTP_", "DARKBLOOM_SPEC_DEC_", "DARKBLOOM_ENGINE_V2", "DARKBLOOM_TESTBED_", "DARKBLOOM_ACTIVATION_", "DARKBLOOM_MEM_"} {
			if strings.HasPrefix(name, prefix) {
				return fmt.Errorf("unset inherited default-policy override %s", name)
			}
		}
	}
	return nil
}

func releaseDefaultSuite(in connectedCacheInput, relay *testbed.ProviderWireRelay) testbed.SuiteConfig {
	return testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{ModelID: in.Artifact.ModelID, NumProviders: 1}}, NumUsers: 1, UseMemoryStore: true,
		CatalogModels: in.Catalog, ProviderRelay: relay, EnableEphemeralPrefixCache: true,
		// Empty cache mode leaves the production global default and exact-model gate in control.
		PrefixCacheMode: "", KVBackend: "auto", ExpectKVBackend: "paged", MaxConcurrent: 1, MTPMode: "auto",
	}
}

func validateReleaseDefaultSlots(slots []connectedSlot, in connectedCacheInput, expected releaseDefaultExpectation) error {
	if len(slots) != 1 {
		return fmt.Errorf("one loaded provider required")
	}
	s := slots[0]
	if s.Model != in.Artifact.ModelID || s.Aggregate != in.Artifact.ModelAggregateSHA256 || s.Capacity == nil || s.CacheStatus == nil || s.CacheStatus.ModelID != in.Artifact.ModelID || s.CacheStatus.Backend != "paged" || s.MemoryCapability != nil {
		return fmt.Errorf("loaded identity/cache status missing or resident cache enabled")
	}
	found := false
	for _, capacity := range s.Capacity.Slots {
		if capacity.Model == in.Artifact.ModelID {
			found = true
			if capacity.KVBackend == nil || *capacity.KVBackend != "paged" || capacity.KVBackendFallbackReason != nil {
				return fmt.Errorf("auto did not construct paged without fallback")
			}
		}
	}
	if !found {
		return fmt.Errorf("loaded capacity missing")
	}
	if expected.cache == "ssd" {
		if s.Capability == nil || !s.Capability.Enabled || !s.Capability.Ready || s.Capability.ModelID != in.Artifact.ModelID || s.Capability.ModelAggregateHash != in.Artifact.ModelAggregateSHA256 || s.Capability.PromptContractID != in.Artifact.PromptContractID || s.CacheStatus.State != "ready" || s.CacheStatus.Reason != "ready" {
			return fmt.Errorf("default Qwen SSD not ready")
		}
	} else if s.Capability != nil || s.CacheStatus.State != "disabled" || s.CacheStatus.Reason != "config_disabled" {
		return fmt.Errorf("default target unexpectedly enabled SSD")
	}
	return nil
}

func TestReleaseDefaultSelectionSeparatesRequestedAndObservedPolicy(t *testing.T) {
	for _, model := range []string{"qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp", "gpt-oss-20b", "gemma-4-26b-qat-4bit"} {
		cache := "ssd"
		if model == "gpt-oss-20b" || model == "gemma-4-26b-qat-4bit" {
			cache = "off"
		}
		in := connectedCacheInput{Backend: "auto", MTPMode: "auto", CacheMode: cache, MaxConcurrent: 1}
		in.Artifact.ModelID = model
		got, err := releaseDefaultSelection(in)
		require.NoError(t, err)
		require.Equal(t, cache, got.cache)
		cfg := releaseDefaultSuite(in, nil)
		require.Empty(t, cfg.PrefixCacheMode)
		require.Equal(t, "auto", cfg.KVBackend)
		require.Equal(t, "paged", cfg.ExpectKVBackend)
		require.Equal(t, "auto", cfg.MTPMode)
		config, err := testbed.BuildProviderTOML(testbed.ProviderConfig{KVBackend: cfg.KVBackend, MTPMode: cfg.MTPMode, MaxConcurrent: 1}, 0)
		require.NoError(t, err)
		require.Contains(t, config, `mtp_mode = "auto"`)
		for _, mutate := range []func(*connectedCacheInput){func(x *connectedCacheInput) { x.Backend = "paged" }, func(x *connectedCacheInput) { x.MTPMode = "off" }, func(x *connectedCacheInput) { x.AssistantPath = "/assistant" }, func(x *connectedCacheInput) { x.MaxConcurrent = 2 }, func(x *connectedCacheInput) { x.Artifact.ModelID = "gemma-4-26b" }} {
			changed := in
			mutate(&changed)
			_, err = releaseDefaultSelection(changed)
			require.Error(t, err)
		}
	}
}
func TestReleaseDefaultEnvironmentRefusesPolicyOverrides(t *testing.T) {
	require.NoError(t, releaseDefaultEnvironment([]string{"PATH=/bin", "MLX_COMPILED_DECODE=1"}))
	for _, key := range []string{"DARKBLOOM_PREFIX_CACHE=0", "DARKBLOOM_PREFIX_CACHE_MODEL_IDS=gemma-4-26b-qat-4bit", "DARKBLOOM_PREFIX_CACHE_MEMORY=1", "DARKBLOOM_CBV2_PAGED_KV=0", "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND=contiguous", "DARKBLOOM_MTP_MAX_TOKENS=0"} {
		require.Error(t, releaseDefaultEnvironment([]string{key}))
	}
}

func TestReleaseDefaultSlotsRejectFallbackAndWrongCacheState(t *testing.T) {
	paged := "paged"
	for _, model := range []string{"gpt-oss-20b", "EigenLabs/Qwen3.8-27B-4bit-mtp"} {
		in := connectedCacheInput{}
		in.Artifact.ModelID = model
		in.Artifact.ModelAggregateSHA256 = "hash"
		in.Artifact.PromptContractID = "contract"
		want := releaseDefaultExpectation{cache: "off"}
		state := "disabled"
		if model != "gpt-oss-20b" {
			want.cache = "ssd"
			state = "ready"
		}
		makeSlot := func() connectedSlot {
			slot := connectedSlot{Model: model, Aggregate: "hash", CacheStatus: &protocol.PrefixCacheModelStatus{ModelID: model, Backend: "paged", State: state, Reason: map[string]string{"ready": "ready", "disabled": "config_disabled"}[state]}, Capacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: model, KVBackend: &paged}}}}
			if want.cache == "ssd" {
				slot.Capability = &protocol.PrefixCacheV2Capability{Enabled: true, Ready: true, ModelID: model, ModelAggregateHash: "hash", PromptContractID: "contract"}
			}
			return slot
		}
		require.NoError(t, validateReleaseDefaultSlots([]connectedSlot{makeSlot()}, in, want))
		for _, mutate := range []func(*connectedSlot){func(s *connectedSlot) { s.CacheStatus = nil }, func(s *connectedSlot) { s.CacheStatus.State = "error" }, func(s *connectedSlot) { s.Capacity.Slots[0].KVBackend = nil }, func(s *connectedSlot) { reason := "fallback"; s.Capacity.Slots[0].KVBackendFallbackReason = &reason }, func(s *connectedSlot) { s.Aggregate = "other" }, func(s *connectedSlot) { s.MemoryCapability = &protocol.PrefixCacheV2Capability{Ready: true} }} {
			bad := makeSlot()
			mutate(&bad)
			require.Error(t, validateReleaseDefaultSlots([]connectedSlot{bad}, in, want))
		}
		if want.cache == "ssd" {
			for _, mutate := range []func(*protocol.PrefixCacheV2Capability){func(c *protocol.PrefixCacheV2Capability) { c.Enabled = false }, func(c *protocol.PrefixCacheV2Capability) { c.Ready = false }, func(c *protocol.PrefixCacheV2Capability) { c.ModelID = "other" }, func(c *protocol.PrefixCacheV2Capability) { c.ModelAggregateHash = "other" }, func(c *protocol.PrefixCacheV2Capability) { c.PromptContractID = "other" }} {
				bad := makeSlot()
				mutate(bad.Capability)
				require.Error(t, validateReleaseDefaultSlots([]connectedSlot{bad}, in, want))
			}
		}
		wrongTier := makeSlot()
		if want.cache == "ssd" {
			wrongTier.Capability = nil
		} else {
			wrongTier.Capability = &protocol.PrefixCacheV2Capability{Ready: true}
		}
		require.Error(t, validateReleaseDefaultSlots([]connectedSlot{wrongTier}, in, want))
	}
}

// Cache-hit accounting may differ; generated output and total token accounting may not.
func validateReleaseDefaultRepeat(a, b connectedStream) error {
	if a.Content != b.Content || a.Reasoning != b.Reasoning || a.Finish != b.Finish || !reflect.DeepEqual(a.Tools, b.Tools) {
		return fmt.Errorf("cold/repeat output mismatch")
	}
	type usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	}
	var counts [2]usage
	for i, stream := range []connectedStream{a, b} {
		if err := json.Unmarshal(stream.Usage, &counts[i]); err != nil {
			return err
		}
		u := counts[i]
		if u.PromptTokens <= 0 || u.CompletionTokens <= 0 || u.TotalTokens != u.PromptTokens+u.CompletionTokens {
			return fmt.Errorf("missing or inconsistent token accounting")
		}
	}
	if counts[0] != counts[1] {
		return fmt.Errorf("cold/repeat token accounting mismatch")
	}
	return nil
}

func TestReleaseDefaultRepeatRequiresCompleteOutputAndTokenAccounting(t *testing.T) {
	makeStream := func() connectedStream {
		return connectedStream{Content: "answer", Reasoning: "reason", Finish: "length", Tools: map[int]connectedTool{0: {ID: "id", Name: "tool", Arguments: "{}"}}, Usage: json.RawMessage(`{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":0}}`)}
	}
	a, b := makeStream(), makeStream()
	b.Usage = json.RawMessage(`{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":8}}`)
	require.NoError(t, validateReleaseDefaultRepeat(a, b))
	for _, mutate := range []func(*connectedStream){
		func(s *connectedStream) { s.Content = "other" }, func(s *connectedStream) { s.Reasoning = "other" }, func(s *connectedStream) { s.Finish = "stop" }, func(s *connectedStream) { s.Tools[0] = connectedTool{Name: "other"} },
		func(s *connectedStream) {
			s.Usage = json.RawMessage(`{"prompt_tokens":11,"completion_tokens":2,"total_tokens":13}`)
		},
		func(s *connectedStream) {
			s.Usage = json.RawMessage(`{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}`)
		},
		func(s *connectedStream) {
			s.Usage = json.RawMessage(`{"prompt_tokens":10,"completion_tokens":2,"total_tokens":11}`)
		},
		func(s *connectedStream) {
			s.Usage = json.RawMessage(`{"prompt_tokens":0,"completion_tokens":2,"total_tokens":2}`)
		},
		func(s *connectedStream) {
			s.Usage = json.RawMessage(`{"prompt_tokens":10,"completion_tokens":0,"total_tokens":10}`)
		},
		func(s *connectedStream) { s.Usage = nil },
	} {
		bad := makeStream()
		mutate(&bad)
		require.Error(t, validateReleaseDefaultRepeat(a, bad))
	}
}
