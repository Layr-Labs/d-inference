package testbed

import (
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// These tests drive the REAL registry (Register + Heartbeat, the same ingest
// path a live provider's frames take), not a stub of it: the assertion under
// test exists because "looked verified" and "was verified" diverged once
// already, and a mocked registry would let them diverge again silently.

func kvExpectationLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(&strings.Builder{}, nil))
}

func registerExpectationProvider(r *registry.Registry, id string, models ...string) {
	infos := make([]protocol.ModelInfo, 0, len(models))
	for _, m := range models {
		infos = append(infos, protocol.ModelInfo{ID: m, ModelType: "gpt_oss", Quantization: "4bit"})
	}
	r.Register(id, nil, &protocol.RegisterMessage{
		Type:    "register",
		Backend: "mlx",
		Models:  infos,
	})
}

func heartbeatKVBackend(r *registry.Registry, id string, backendByModel map[string]string) {
	slots := make([]protocol.BackendSlotCapacity, 0, len(backendByModel))
	for model, backend := range backendByModel {
		b := backend
		slots = append(slots, protocol.BackendSlotCapacity{
			Model:     model,
			State:     "running",
			KVBackend: &b,
		})
	}
	r.Heartbeat(id, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         slots,
		},
	})
}

func TestResolveExpectedKVBackendValidatesInsteadOfDisarming(t *testing.T) {
	t.Setenv(EnvExpectKVBackend, "")

	if got, err := ResolveExpectedKVBackend(""); err != nil || got != "" {
		t.Fatalf("unset expectation = (%q, %v), want disabled with no error", got, err)
	}
	if got, err := ResolveExpectedKVBackend(KVBackendPaged); err != nil || got != KVBackendPaged {
		t.Fatalf("explicit paged = (%q, %v)", got, err)
	}

	t.Setenv(EnvExpectKVBackend, KVBackendContiguous)
	if got, err := ResolveExpectedKVBackend(""); err != nil || got != KVBackendContiguous {
		t.Fatalf("env contiguous = (%q, %v)", got, err)
	}
	// Suite config wins over env, mirroring the KVBackend request knob.
	if got, err := ResolveExpectedKVBackend(KVBackendPaged); err != nil || got != KVBackendPaged {
		t.Fatalf("explicit-over-env = (%q, %v)", got, err)
	}

	// A typo must be a hard error: silently disarming the assertion is the
	// exact failure mode this knob exists to remove.
	t.Setenv(EnvExpectKVBackend, "pagd")
	if _, err := ResolveExpectedKVBackend(""); err == nil {
		t.Fatal("misspelled expectation resolved silently instead of failing")
	}
	// "auto" is a request, not an observable build — reject it too.
	if _, err := ResolveExpectedKVBackend("auto"); err == nil {
		t.Fatal("'auto' accepted as an expectation; only built kinds are assertable")
	}
}

func TestVerifyRegistryKVBackendsPassesWhenEverySlotMatches(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerExpectationProvider(r, "box-a", "m/one")
	registerExpectationProvider(r, "box-b", "m/one", "m/two")
	heartbeatKVBackend(r, "box-a", map[string]string{"m/one": registry.KVBackendPaged})
	heartbeatKVBackend(r, "box-b", map[string]string{
		"m/one": registry.KVBackendPaged,
		"m/two": registry.KVBackendPaged,
	})

	err := VerifyRegistryKVBackends(
		context.Background(), r, KVBackendPaged, 5*time.Second, kvExpectationLogger())
	if err != nil {
		t.Fatalf("all-paged fleet failed a paged expectation: %v", err)
	}
}

func TestVerifyRegistryKVBackendsFailsFastOnMismatchWithFallbackReason(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerExpectationProvider(r, "box-degraded", "m/one")
	backend := registry.KVBackendContiguous
	reason := "kernel_preflight: paged decode kernel failed self-check"
	r.Heartbeat("box-degraded", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model:                   "m/one",
				State:                   "running",
				KVBackend:               &backend,
				KVBackendFallbackReason: &reason,
			}},
		},
	})

	start := time.Now()
	err := VerifyRegistryKVBackends(
		context.Background(), r, KVBackendPaged, 30*time.Second, kvExpectationLogger())
	if err == nil {
		t.Fatal("a contiguous slot passed a paged expectation — the silent-degrade hole is back")
	}
	// Mismatch is a verdict, not a wait: it must not burn the deadline.
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("mismatch took %v to report; must fail fast, not poll out the deadline", elapsed)
	}
	for _, want := range []string{registry.KVBackendContiguous, "kernel_preflight", EnvExpectKVBackend} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("mismatch error %q does not name %q", err.Error(), want)
		}
	}
}

func TestVerifyRegistryKVBackendsFailsWhenNothingEverReports(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	// Registered, advertises a model, but never heartbeats a slot — the
	// pre-0.8.0 provider shape, or a load that never completed. "Could not
	// verify" must be a failure that names the slot, not a green.
	registerExpectationProvider(r, "box-silent", "m/one")

	err := VerifyRegistryKVBackends(
		context.Background(), r, KVBackendPaged, 1500*time.Millisecond, kvExpectationLogger())
	if err == nil {
		t.Fatal("an unobservable fleet passed the expectation")
	}
	if !strings.Contains(err.Error(), "box-silent/m/one") {
		t.Fatalf("timeout error %q does not name the unverified slot", err.Error())
	}
}

func TestVerifyRegistryKVBackendsWaitsForALateFirstHeartbeat(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	registerExpectationProvider(r, "box-lazy", "m/one")

	// The production sequence: registration first, engine construction and
	// the first capacity heartbeat only after the pre-warm load completes.
	go func() {
		time.Sleep(400 * time.Millisecond)
		heartbeatKVBackend(r, "box-lazy", map[string]string{"m/one": registry.KVBackendPaged})
	}()

	err := VerifyRegistryKVBackends(
		context.Background(), r, KVBackendPaged, 10*time.Second, kvExpectationLogger())
	if err != nil {
		t.Fatalf("late-but-matching heartbeat failed the expectation: %v", err)
	}
}

func TestVerifyRegistryKVBackendsRefusesAnEmptyFleet(t *testing.T) {
	r := registry.New(kvExpectationLogger())
	err := VerifyRegistryKVBackends(
		context.Background(), r, KVBackendPaged, time.Second, kvExpectationLogger())
	if err == nil {
		t.Fatal("expectation with nothing to assert must fail, not vacuously pass")
	}
}
