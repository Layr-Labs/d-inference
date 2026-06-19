package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestClassifyLoadFailure(t *testing.T) {
	cases := []struct {
		name string
		err  string
		want string
	}{
		// Draining is the well-known transient reason sent verbatim by the
		// provider; pin it against the protocol constant so the two cannot drift.
		{"draining_constant", protocol.ProviderDrainingForUpdate, loadFailureDraining},
		{"draining_substring", "Provider DRAINING for update", loadFailureDraining},

		// Insufficient memory: the raw dispatch string, evictUntilAvailable's
		// formatted string, and the post-load KV-headroom guard.
		{"insufficient_memory_dispatch", "insufficient memory to load model 'gpt-oss-20b'", loadFailureInsufficientMemory},
		{"insufficient_memory_formatted", "Insufficient memory (3.1 GB free, need 12.0 GB) and all loaded models are actively serving", loadFailureInsufficientMemory},
		{"insufficient_kv_headroom", "Model 'gpt-oss-20b' loaded but has insufficient KV headroom for one request", loadFailureInsufficientMemory},
		{"out_of_memory", "Metal: out of memory", loadFailureInsufficientMemory},
		{"gpu_oom_token", "GPU OOM", loadFailureInsufficientMemory},

		// "oom" is matched as a whole token: substrings of unrelated words must
		// NOT land in the memory bucket.
		{"boom_not_oom", "model load failed: boom", loadFailureOther},
		{"no_room_not_oom", "no room left on device", loadFailureOther},

		// Slot cap.
		{"slot_cap", "All 3 model slot(s) are active; cannot load 'gpt-oss-20b'", loadFailureSlotCap},

		// Model not found / not advertised.
		{"not_found_cache", "Model 'gpt-oss-20b' not found in local HuggingFace cache", loadFailureModelNotFound},
		{"not_advertised", "Model 'gpt-oss-20b' not in advertised model list", loadFailureModelNotFound},

		// Other: empty, generic Foundation bridge string (the common proactive
		// case), bare "model load failed", and provider shutdown.
		{"empty", "", loadFailureOther},
		{"whitespace", "   ", loadFailureOther},
		{"foundation_bridge", "The operation couldn’t be completed. (ProviderCore.InferenceError error 1.)", loadFailureOther},
		{"bare_model_load_failed", "model load failed: something opaque", loadFailureOther},
		{"shutting_down", "provider is shutting down", loadFailureOther},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyLoadFailure(tc.err); got != tc.want {
				t.Fatalf("classifyLoadFailure(%q) = %q, want %q", tc.err, got, tc.want)
			}
		})
	}
}

// TestClassifyLoadFailureLowCardinality guards the metric tag contract: the
// classifier must only ever emit the five known reason buckets.
func TestClassifyLoadFailureLowCardinality(t *testing.T) {
	allowed := map[string]struct{}{
		loadFailureInsufficientMemory: {},
		loadFailureSlotCap:            {},
		loadFailureDraining:           {},
		loadFailureModelNotFound:      {},
		loadFailureOther:              {},
	}
	samples := []string{
		"", "garbage", protocol.ProviderDrainingForUpdate,
		"insufficient memory to load model 'x'",
		"All 1 model slot(s) are active; cannot load 'x'",
		"Model 'x' not found in local HuggingFace cache",
		"model load failed: boom",
	}
	for _, s := range samples {
		if _, ok := allowed[classifyLoadFailure(s)]; !ok {
			t.Fatalf("classifyLoadFailure(%q) returned an unlisted reason %q", s, classifyLoadFailure(s))
		}
	}
}

// TestLoadFailureIsPermanent pins the gating that decides short memory backoff
// vs. full TTL cooldown: only model_not_found is permanent (keeps full TTL); the
// transient classes AND the opaque "other" bucket (where real memory pressure
// lands as a bridged generic string) take the short backoff.
func TestLoadFailureIsPermanent(t *testing.T) {
	cases := map[string]bool{
		loadFailureModelNotFound:      true,
		loadFailureInsufficientMemory: false,
		loadFailureSlotCap:            false,
		loadFailureDraining:           false,
		loadFailureOther:              false,
	}
	for reason, want := range cases {
		if got := loadFailureIsPermanent(reason); got != want {
			t.Errorf("loadFailureIsPermanent(%q) = %v, want %v", reason, got, want)
		}
	}
}
