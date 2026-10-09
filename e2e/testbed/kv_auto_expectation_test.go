package testbed

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func registerAutoKVProvider(r *registry.Registry, models ...protocol.ModelInfo) {
	r.Register("auto-box", nil, &protocol.RegisterMessage{
		Type: "register", Backend: "mlx", Models: models,
	})
}

func heartbeatAutoKVSlot(r *registry.Registry, model, backend, state string, budget int64) {
	var tag *string
	if backend != "" {
		tag = &backend
	}
	r.Heartbeat("auto-box", &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model: model, State: state, KVBackend: tag,
				MaxConcurrency: 4, ActiveTokenBudgetMax: budget,
			}},
		},
	})
}

func TestAutomaticKVPrewarmPackedAndMiMoUseRegisteredTypes(t *testing.T) {
	for _, precision := range []string{"", "balanced", " K4V4 ", "int4", "on", "k8v4", "k8v8", "int8"} {
		t.Run(precision, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			// Arbitrary IDs ensure the policy comes from registration metadata.
			registerAutoKVProvider(r,
				protocol.ModelInfo{ID: "arbitrary/ar", ModelType: "gpt_oss", Quantization: "4bit"},
				protocol.ModelInfo{ID: "arbitrary/native", ModelType: "mimo_v2", Quantization: "4bit"})
			loads := 0
			var loaded []protocol.BackendSlotCapacity
			err := verifyAutomaticRegistryKVBackends(context.Background(), r, precision,
				time.Second, kvExpectationLogger(), func(provider, model string) error {
					loads++
					backend := KVBackendPaged
					if model == "arbitrary/native" {
						backend = KVBackendContiguous
					}
					loaded = append(loaded, protocol.BackendSlotCapacity{
						Model: model, State: "idle", KVBackend: &backend,
						MaxConcurrency: 4, ActiveTokenBudgetMax: 1024,
					})
					r.Heartbeat(provider, &protocol.HeartbeatMessage{
						Type: protocol.TypeHeartbeat, Status: "serving",
						BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: loaded},
					})
					return nil
				})
			if err != nil || loads != 2 {
				t.Fatalf("mixed precision %q: err=%v loads=%d, want both actual warm slots", precision, err, loads)
			}
		})
	}
}

func TestAutomaticKVPrewarmRejectsPackedAndMiMoBackendMismatch(t *testing.T) {
	for _, tc := range []struct{ modelType, backend string }{
		{"gpt_oss", KVBackendContiguous},
		{"mimo_v2", KVBackendPaged},
	} {
		t.Run(tc.modelType, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: tc.modelType, Quantization: "4bit"})
			err := verifyAutomaticRegistryKVBackends(context.Background(), r, "balanced",
				time.Second, kvExpectationLogger(), func(string, string) error {
					heartbeatAutoKVSlot(r, "model", tc.backend, "idle", 1024)
					return nil
				})
			if err == nil || !strings.Contains(err.Error(), "built exact slot") {
				t.Fatalf("mismatched %s/%s passed: %v", tc.modelType, tc.backend, err)
			}
		})
	}
}

func TestAutomaticKVPrewarmRejectsEarlierSlotEviction(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r,
		protocol.ModelInfo{ID: "first", ModelType: "qwen3", Quantization: "4bit"},
		protocol.ModelInfo{ID: "second", ModelType: "qwen3", Quantization: "4bit"})
	err := verifyAutomaticRegistryKVBackends(context.Background(), r, "native",
		time.Second, kvExpectationLogger(), func(provider, model string) error {
			// Each row is individually warm, but the later heartbeat removes
			// the earlier model. This is not a steady warm serving set.
			heartbeatAutoKVSlot(r, model, KVBackendContiguous, "idle", 1024)
			return nil
		})
	if err == nil || !strings.Contains(err.Error(), "first lost usable capacity") {
		t.Fatalf("evicted model reached the measured topology: %v", err)
	}
}

func TestAutomaticKVPrewarmNativeAcceptsActualResolvedBackends(t *testing.T) {
	for _, precision := range []string{"native", "off", "0", " NATIVE\n"} {
		for _, backend := range []string{KVBackendPaged, KVBackendContiguous} {
			t.Run(precision+"/"+backend, func(t *testing.T) {
				r := registry.New(kvExpectationLogger())
				registerAutoKVProvider(r, protocol.ModelInfo{ID: "unknown-to-testbed", ModelType: "qwen3", Quantization: "4bit"})
				loads := 0
				err := verifyAutomaticRegistryKVBackends(context.Background(), r, precision,
					time.Second, kvExpectationLogger(), func(string, string) error {
						loads++
						heartbeatAutoKVSlot(r, "unknown-to-testbed", backend, "idle", 1024)
						return nil
					})
				if err != nil || loads != 1 {
					t.Fatalf("native %q actual %q: err=%v loads=%d", precision, backend, err, loads)
				}
			})
		}
	}
}

func TestAutomaticKVPrewarmNativeRequiresConcreteUsableHeartbeat(t *testing.T) {
	for _, tc := range []struct {
		name, backend, state string
		budget               int64
	}{
		{"missing backend", "", "idle", 1024},
		{"unknown backend", "pagd", "idle", 1024},
		{"no usable budget", KVBackendContiguous, "idle", 0},
		{"busy slot", KVBackendPaged, "running", 1024},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
			err := verifyAutomaticRegistryKVBackends(context.Background(), r, "native",
				15*time.Millisecond, kvExpectationLogger(), func(string, string) error {
					heartbeatAutoKVSlot(r, "model", tc.backend, tc.state, tc.budget)
					return nil
				})
			if err == nil {
				t.Fatal("automatic native prewarm passed without a concrete usable slot")
			}
		})
	}
}

func TestAutomaticKVPrewarmNativeRecordsActualFallbackProvenance(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
	var recorded strings.Builder
	logger := slog.New(slog.NewTextHandler(&recorded, nil))
	err := verifyAutomaticRegistryKVBackends(context.Background(), r, "native",
		time.Second, logger, func(string, string) error {
			backend, fallback := KVBackendContiguous, "kernel_preflight: native paged construction refused"
			r.Heartbeat("auto-box", &protocol.HeartbeatMessage{
				Type: protocol.TypeHeartbeat, Status: "serving",
				BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64,
					Slots: []protocol.BackendSlotCapacity{{
						Model: "model", State: "idle", MaxConcurrency: 4, ActiveTokenBudgetMax: 1024,
						KVBackend: &backend, KVBackendFallbackReason: &fallback,
					}}},
			})
			return nil
		})
	if err != nil {
		t.Fatalf("actual native fallback failed prewarm: %v", err)
	}
	for _, field := range []string{"model_type=qwen3", "kv_precision=native", "expected=native_auto",
		"kv_backend=contiguous", "kv_backend_fallback=kernel_preflight"} {
		if !strings.Contains(recorded.String(), field) {
			t.Fatalf("native auto provenance omitted %q: %s", field, recorded.String())
		}
	}
}

func TestAutomaticKVPrewarmValidatesPrecisionAndModelMetadata(t *testing.T) {
	for _, tc := range []struct{ modelType, precision string }{
		{"qwen3", "balnced"},
		{"", "native"},
	} {
		r := registry.New(kvExpectationLogger())
		registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: tc.modelType, Quantization: "4bit"})
		loads := 0
		err := verifyAutomaticRegistryKVBackends(context.Background(), r, tc.precision,
			time.Second, kvExpectationLogger(), func(string, string) error { loads++; return nil })
		if err == nil || loads != 0 {
			t.Fatalf("invalid metadata/precision reached load: err=%v loads=%d", err, loads)
		}
	}
	// Serving excludes exact MiMo before parsing even a malformed override.
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "mimo_v2", Quantization: "4bit"})
	err := verifyAutomaticRegistryKVBackends(context.Background(), r, "balnced",
		time.Second, kvExpectationLogger(), func(string, string) error {
			heartbeatAutoKVSlot(r, "model", KVBackendContiguous, "idle", 1024)
			return nil
		})
	if err != nil {
		t.Fatalf("MiMo native exclusion did not precede precision parsing: %v", err)
	}
}

func TestAutomaticKVPrewarmPreservesExplicitExpectedBackend(t *testing.T) {
	t.Setenv(EnvExpectKVBackend, "")
	t.Setenv(EnvKVQuantization, "native")
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
	heartbeatAutoKVSlot(r, "model", KVBackendContiguous, "idle", 1024)
	suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
		Coordinator: &Coordinator{Registry: r},
		Config:      SuiteConfig{ExpectKVBackend: KVBackendPaged, PrewarmAutomaticKVBackend: true}}
	if err := suite.verifyKVBackendExpectation(); err == nil || !strings.Contains(err.Error(), "built kv_backend") {
		t.Fatalf("automatic native policy disarmed explicit paged assertion: %v", err)
	}
	// The private native-auto predicate must not become an operator expectation.
	if _, err := ResolveExpectedKVBackend(nativeAutoBackend); err == nil {
		t.Fatal("native auto disarmed the exact expected-backend declaration")
	}
}

func TestProviderStartSpecPreservesKVPrecisionForOwnedHosts(t *testing.T) {
	for _, precision := range []string{"native", "off", "0", "balanced", "k8v4", "k8v8", "", "balnced"} {
		t.Run(precision, func(t *testing.T) {
			t.Setenv(EnvKVQuantization, precision)
			spec, err := buildProviderStartSpec("http://127.0.0.1:8123", t.TempDir(),
				ProviderConfig{ModelID: "model", KVBackend: KVBackendAuto}, 0)
			if err != nil {
				t.Fatalf("prepare owned precision control: %v", err)
			}
			actual, present := spec.Environment[EnvKVQuantization]
			if !present || actual != precision {
				t.Fatalf("owned launch lost exact precision override: got %q present=%t, want %q", actual, present, precision)
			}
			if !strings.Contains(spec.Config, `engine_v2_kv_backend = "auto"`) {
				t.Fatal("precision override changed the requested automatic backend")
			}
		})
	}
}

func TestProviderStartSpecPreservesContiguousNativePinWithoutOverride(t *testing.T) {
	t.Setenv(EnvKVQuantization, "temporary")
	if err := os.Unsetenv(EnvKVQuantization); err != nil {
		t.Fatal(err)
	}
	spec, err := buildProviderStartSpec("http://127.0.0.1:8123", t.TempDir(),
		ProviderConfig{ModelID: "model", KVBackend: KVBackendContiguous}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, present := spec.Environment[EnvKVQuantization]; present {
		t.Fatal("unset precision installed an override over the native contiguous fixture")
	}
	if !strings.Contains(spec.Config, `engine_v2_kv_quantization = "native"`) {
		t.Fatal("contiguous fixture lost its native precision pin")
	}
}

func TestProviderStartSpecContiguousControlOverridesAmbientPrecision(t *testing.T) {
	for _, precision := range []string{"balanced", "k8v4", "k8v8", "native", "balnced", ""} {
		for _, backend := range []string{KVBackendContiguous, ""} {
			t.Run(precision+"/"+backend, func(t *testing.T) {
				t.Setenv(EnvKVQuantization, precision)
				t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendContiguous)
				spec, err := buildProviderStartSpec("http://127.0.0.1:8123", t.TempDir(),
					ProviderConfig{ModelID: "model", KVBackend: backend}, 0)
				if err != nil {
					t.Fatal(err)
				}
				if spec.Environment[EnvKVQuantization] != "native" ||
					!strings.Contains(spec.Config, `engine_v2_kv_backend = "contiguous"`) ||
					!strings.Contains(spec.Config, `engine_v2_kv_quantization = "native"`) {
					t.Fatalf("contiguous control inherited ambient precision %q: %+v", precision, spec)
				}
			})
		}
	}
}

func TestProviderStartSpecExplicitPagedAndAutoPreservePrecisionOverContiguousEnvironment(t *testing.T) {
	for _, backend := range []string{KVBackendPaged, KVBackendAuto} {
		for _, precision := range []string{"balanced", "k8v4", "k8v8", "native", "balnced"} {
			t.Run(backend+"/"+precision, func(t *testing.T) {
				t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendContiguous)
				t.Setenv(EnvKVQuantization, precision)
				spec, err := buildProviderStartSpec("http://127.0.0.1:8123", t.TempDir(),
					ProviderConfig{ModelID: "model", KVBackend: backend}, 0)
				if err != nil {
					t.Fatal(err)
				}
				if spec.Environment[EnvKVQuantization] != precision ||
					!strings.Contains(spec.Config, `engine_v2_kv_backend = "`+backend+`"`) {
					t.Fatalf("explicit %s lost precision/backend precedence: %+v", backend, spec)
				}
			})
		}
	}
}
