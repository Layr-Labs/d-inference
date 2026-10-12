package testbed

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func automaticKVStateFixture(t *testing.T, r *registry.Registry, providerID, model, backend, precision string) (*Provider, map[string]any) {
	t.Helper()
	account := "testbed-" + providerID
	registered := r.GetProvider(providerID)
	registered.Mu().Lock()
	registered.AccountID = account
	registered.ModelAutopilot = &protocol.ModelAutopilotState{Enabled: true}
	registered.Mu().Unlock()
	// Exercise the real bounded state-file reader without launching a provider.
	provider := &Provider{AccountID: account, StateDir: t.TempDir(),
		cmd: &os.Process{Pid: os.Getpid()}, done: make(chan struct{})}
	state := map[string]any{
		"schema": 1, "pid": os.Getpid(), "written_at": float64(time.Now().UnixMilli()) / 1000,
		"slots": []map[string]any{{"model": model, "kv_backend": backend,
			"kv_quantization": precision, "kv_checkpoint_quantization": "balanced"}},
	}
	return provider, state
}

func writeAutomaticKVState(t *testing.T, provider *Provider, state map[string]any) {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(provider.DaemonStatePath(), raw, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestAutomaticKVPrecisionRejectsInvalidState(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		change     func(map[string]any)
	}{
		{"missing precision", "kv_quantization", func(state map[string]any) {
			delete(state["slots"].([]map[string]any)[0], "kv_quantization")
		}},
		{"null precision", "kv_quantization", func(state map[string]any) {
			state["slots"].([]map[string]any)[0]["kv_quantization"] = nil
		}},
		{"unknown precision", "kv_quantization", func(state map[string]any) {
			state["slots"].([]map[string]any)[0]["kv_quantization"] = "default"
		}},
		{"native checkpoint cannot vouch for live KV", "kv_quantization", func(state map[string]any) {
			slot := state["slots"].([]map[string]any)[0]
			slot["kv_quantization"], slot["kv_checkpoint_quantization"] = "balanced", "native"
		}},
		{"duplicate model", "ambiguous state", func(state map[string]any) {
			state["slots"] = append(state["slots"].([]map[string]any), map[string]any{
				"model": "model", "kv_backend": KVBackendPaged, "kv_quantization": "balanced"})
		}},
		{"missing model", "no matching model slot", func(state map[string]any) {
			state["slots"].([]map[string]any)[0]["model"] = "other"
		}},
		{"missing slots", "no matching model slot", func(state map[string]any) { delete(state, "slots") }},
		{"missing backend", "no matching resolved backend", func(state map[string]any) {
			delete(state["slots"].([]map[string]any)[0], "kv_backend")
		}},
		{"different backend", "no matching resolved backend", func(state map[string]any) {
			state["slots"].([]map[string]any)[0]["kv_backend"] = KVBackendContiguous
		}},
		{"load failure", "no matching resolved backend", func(state map[string]any) {
			state["slots"].([]map[string]any)[0]["load_error"] = "load refused"
		}},
		{"wrong process", "want fixture pid", func(state map[string]any) { state["pid"] = os.Getpid() + 1 }},
		{"missing process", "want fixture pid", func(state map[string]any) { delete(state, "pid") }},
		{"stale snapshot", "state is stale", func(state map[string]any) {
			state["written_at"] = float64(time.Now().Add(-time.Minute).UnixMilli()) / 1000
		}},
		{"future snapshot", "invalid written_at", func(state map[string]any) {
			state["written_at"] = float64(time.Now().Add(time.Minute).UnixMilli()) / 1000
		}},
		{"missing timestamp", "invalid written_at", func(state map[string]any) { delete(state, "written_at") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
			heartbeatAutoKVSlot(r, "model", KVBackendPaged, "idle", 1024)
			provider, state := automaticKVStateFixture(t, r, "auto-box", "model", KVBackendPaged, "native")
			tc.change(state)
			writeAutomaticKVState(t, provider, state)
			suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
				Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
			err := suite.verifyAutomaticKVBackendExpectation("", 250*time.Millisecond)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid state passed or wrong failure: %v, want %q", err, tc.want)
			}
		})
	}
}

func TestAutomaticKVPrecisionRequiresReadableState(t *testing.T) {
	for _, tc := range []struct{ name, raw, want string }{
		{"missing file", "", "state not yet reported"},
		{"malformed JSON", "{", "decode provider"},
		{"null state", "null", "want fixture pid"},
		{"oversized state", strings.Repeat(" ", (1<<20)+1), "state exceeds limit"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
			heartbeatAutoKVSlot(r, "model", KVBackendPaged, "idle", 1024)
			provider, _ := automaticKVStateFixture(t, r, "auto-box", "model", KVBackendPaged, "native")
			if tc.raw != "" {
				if err := os.WriteFile(provider.DaemonStatePath(), []byte(tc.raw), 0600); err != nil {
					t.Fatal(err)
				}
			}
			suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
				Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
			err := suite.verifyAutomaticKVBackendExpectation("", 250*time.Millisecond)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("unreadable state passed or wrong failure: %v, want %q", err, tc.want)
			}
		})
	}
}

func TestAutomaticKVPrecisionRequiresUniqueLiveFixture(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		change     func(*Suite)
	}{
		{"missing fixture", "no account-bound fixture", func(s *Suite) { s.Providers = nil }},
		{"wrong account", "no account-bound fixture", func(s *Suite) { s.Providers[0].AccountID = "other" }},
		{"duplicate fixture", "multiple fixture handles", func(s *Suite) { s.Providers = append(s.Providers, s.Providers[0]) }},
		{"duplicate registration", "ambiguous fixture account", func(s *Suite) {
			s.Coordinator.Registry.Register("other-box", nil, &protocol.RegisterMessage{Type: "register", Backend: "mlx"})
			other := s.Coordinator.Registry.GetProvider("other-box")
			other.Mu().Lock()
			other.AccountID = s.Providers[0].AccountID
			other.Mu().Unlock()
		}},
		{"unstarted fixture", "no started fixture process", func(s *Suite) { s.Providers[0].cmd = nil }},
		{"exited fixture", "exited before live KV precision", func(s *Suite) { close(s.Providers[0].done) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
			heartbeatAutoKVSlot(r, "model", KVBackendPaged, "idle", 1024)
			provider, state := automaticKVStateFixture(t, r, "auto-box", "model", KVBackendPaged, "native")
			writeAutomaticKVState(t, provider, state)
			suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
				Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
			tc.change(&suite)
			err := suite.verifyAutomaticKVBackendExpectation("", time.Second)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid fixture passed or wrong failure: %v, want %q", err, tc.want)
			}
		})
	}
}

func TestAutomaticKVPrecisionWaitsForStatePublication(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
	heartbeatAutoKVSlot(r, "model", KVBackendPaged, "idle", 1024)
	provider, state := automaticKVStateFixture(t, r, "auto-box", "model", KVBackendPaged, "native")
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	staged := filepath.Join(provider.StateDir, "next-state.json")
	if err := os.WriteFile(staged, raw, 0600); err != nil {
		t.Fatal(err)
	}
	published := make(chan error, 1)
	go func() {
		time.Sleep(10 * time.Millisecond)
		published <- os.Rename(staged, provider.DaemonStatePath())
	}()
	suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
		Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
	err = suite.verifyAutomaticKVBackendExpectation("", time.Second)
	if publishErr := <-published; publishErr != nil {
		t.Fatal(publishErr)
	}
	if err != nil {
		t.Fatalf("fresh state published after the ready heartbeat was rejected: %v", err)
	}
}

func TestAutomaticKVPrecisionBindsStateToProviderAccount(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	var providers []*Provider
	var states []map[string]any
	for _, id := range []string{"box-a", "box-b"} {
		r.Register(id, nil, &protocol.RegisterMessage{Type: "register", Backend: "mlx",
			Models: []protocol.ModelInfo{{ID: "model", ModelType: "qwen3", Quantization: "4bit"}}})
		backend := KVBackendPaged
		r.Heartbeat(id, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "serving",
			BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64,
				Slots: []protocol.BackendSlotCapacity{{Model: "model", State: "idle", KVBackend: &backend,
					MaxConcurrency: 4, ActiveTokenBudgetMax: 1024}}}})
		provider, state := automaticKVStateFixture(t, r, id, "model", backend, "native")
		writeAutomaticKVState(t, provider, state)
		providers, states = append(providers, provider), append(states, state)
	}
	suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
		Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{providers[1], providers[0]}}
	if err := suite.verifyAutomaticKVBackendExpectation("", time.Second); err != nil {
		t.Fatalf("fixture declaration order changed valid provider binding: %v", err)
	}
	states[1]["slots"].([]map[string]any)[0]["kv_quantization"] = "balanced"
	writeAutomaticKVState(t, providers[1], states[1])
	err := suite.verifyAutomaticKVBackendExpectation("", time.Second)
	if err == nil || !strings.Contains(err.Error(), "provider box-b/model resolved live kv_quantization=\"balanced\"") {
		t.Fatalf("one native provider vouched for a different provider: %v", err)
	}
}

func TestAutomaticKVPrecisionPreservesExplicitBackendLanes(t *testing.T) {
	t.Setenv(EnvExpectKVBackend, "")
	t.Setenv(EnvKVQuantization, "native")
	for _, backend := range []string{KVBackendPaged, KVBackendContiguous} {
		t.Run(backend, func(t *testing.T) {
			r := registry.New(kvExpectationLogger())
			registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "qwen3", Quantization: "4bit"})
			heartbeatAutoKVSlot(r, "model", backend, "idle", 1024)
			automaticKVStateFixture(t, r, "auto-box", "model", backend, "balanced")
			// Explicit backend/exact-cache lanes keep their existing contract;
			// they need neither a native-precision claim nor a local state file.
			suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
				Coordinator: &Coordinator{Registry: r},
				Config:      SuiteConfig{ExpectKVBackend: backend, PrewarmAutomaticKVBackend: true}}
			if err := suite.verifyKVBackendExpectation(); err != nil {
				t.Fatalf("explicit %s lane acquired an automatic native requirement: %v", backend, err)
			}
		})
	}
}

func TestAutomaticKVPrecisionChecksEveryAdvertisedModel(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerAutoKVProvider(r,
		protocol.ModelInfo{ID: "first", ModelType: "qwen3", Quantization: "4bit"},
		protocol.ModelInfo{ID: "second", ModelType: "qwen3", Quantization: "4bit"})
	backend := KVBackendPaged
	r.Heartbeat("auto-box", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: "first", State: "idle", KVBackend: &backend, MaxConcurrency: 4, ActiveTokenBudgetMax: 1024},
				{Model: "second", State: "idle", KVBackend: &backend, MaxConcurrency: 4, ActiveTokenBudgetMax: 1024},
			}}})
	provider, state := automaticKVStateFixture(t, r, "auto-box", "first", backend, "native")
	second := map[string]any{"model": "second", "kv_backend": backend, "kv_quantization": "balanced"}
	state["slots"] = append(state["slots"].([]map[string]any), second)
	writeAutomaticKVState(t, provider, state)
	suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
		Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
	if err := suite.verifyAutomaticKVBackendExpectation("", time.Second); err == nil ||
		!strings.Contains(err.Error(), "auto-box/second resolved live kv_quantization=\"balanced\"") {
		t.Fatalf("native first slot vouched for a different model: %v", err)
	}
	second["kv_quantization"] = "native"
	writeAutomaticKVState(t, provider, state)
	if err := suite.verifyAutomaticKVBackendExpectation("", time.Second); err != nil {
		t.Fatalf("all native model slots did not pass: %v", err)
	}
}

func TestAutomaticKVPrecisionMiMoRemainsNative(t *testing.T) {
	for _, precision := range []string{"", "balanced", "k8v4", "k8v8", "balnced"} {
		for _, live := range []string{"native", "balanced"} {
			t.Run(precision+"/"+live, func(t *testing.T) {
				r := registry.New(kvExpectationLogger())
				registerAutoKVProvider(r, protocol.ModelInfo{ID: "model", ModelType: "mimo_v2", Quantization: "4bit"})
				heartbeatAutoKVSlot(r, "model", KVBackendContiguous, "idle", 1024)
				provider, state := automaticKVStateFixture(t, r, "auto-box", "model", KVBackendContiguous, live)
				writeAutomaticKVState(t, provider, state)
				suite := Suite{Ctx: context.Background(), Logger: kvExpectationLogger(),
					Coordinator: &Coordinator{Registry: r}, Providers: []*Provider{provider}}
				err := suite.verifyAutomaticKVBackendExpectation(precision, time.Second)
				if (err != nil) != (live != "native") {
					t.Fatalf("MiMo precision %q resolved live %q: %v", precision, live, err)
				}
			})
		}
	}
}
