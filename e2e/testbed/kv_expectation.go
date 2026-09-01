package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Built-backend assertion (v0.8.0 gate audit).
//
// Everything else in the KV posture plumbing describes what the testbed ASKS
// the provider for. Nothing asserted what the engine BUILT: an `.auto` slot
// whose paged construction fails degrades to contiguous by design, and an
// explicit-paged lane whose TOML plumbing silently broke would launch on
// `.auto` and degrade the same way — in both cases the "paged" lane measures
// contiguous and stays green. This file closes that hole with the one signal
// that reflects construction truth: `BackendSlotCapacity.KVBackend` on the
// provider heartbeat, which is `EngineV2Bridge.kvBackendKind` — the RESOLVED
// backend after every veto and fallback, per slot, every heartbeat.
//
// A lane declares intent with DARKBLOOM_TESTBED_EXPECT_KV_BACKEND (or the
// SuiteConfig field); the suite then refuses to come up unless every
// (provider, advertised model) slot reports exactly that backend. Slots are
// pre-warmed through the coordinator's own `load_model` push — the same
// pre-warm mechanism production uses — because a freshly-booted testbed
// provider has nothing resident (empty persisted set → `.nothingToPreload`)
// and a backend that was never constructed cannot be observed.

// EnvExpectKVBackend declares the KV backend every engine slot in the suite
// must have actually been BUILT with: "paged" or "contiguous". Empty/unset
// disables the assertion. Distinct from DARKBLOOM_TESTBED_KV_BACKEND, which
// selects what to REQUEST; this one asserts what was CONSTRUCTED, so a lane
// can pin the request, the expectation, or both.
const EnvExpectKVBackend = "DARKBLOOM_TESTBED_EXPECT_KV_BACKEND"

// kvExpectationTimeout bounds the pre-warm + first-observation wait per
// suite. The dominant term is the model load the pre-warm triggers (a 12 GB
// checkpoint paging in from a CI runner's disk); the heartbeat that carries
// the observation follows within the provider's 5s default cadence.
const kvExpectationTimeout = 5 * time.Minute

// ResolveExpectedKVBackend returns the backend the suite must have built:
// the explicit value when set, else DARKBLOOM_TESTBED_EXPECT_KV_BACKEND,
// else "" (assertion disabled). A value that is neither "paged" nor
// "contiguous" is a hard error, not a silent no-op: a typo in this knob
// would otherwise disarm the exact assertion the lane exists to make
// (the same lesson as ResolveMaxConcurrent).
func ResolveExpectedKVBackend(explicit string) (string, error) {
	raw := explicit
	source := "suite config"
	if raw == "" {
		raw = os.Getenv(EnvExpectKVBackend)
		source = "env " + EnvExpectKVBackend
	}
	switch raw {
	case "", KVBackendPaged, KVBackendContiguous:
		return raw, nil
	default:
		return "", fmt.Errorf(
			"%s=%q is not an assertable KV backend (want %q or %q); "+
				"refusing to run with a disarmed backend assertion",
			source, raw, KVBackendPaged, KVBackendContiguous)
	}
}

// verifyKVBackendExpectation is the Suite.Start hook: resolve the declared
// expectation and, when one exists, hold suite startup until every provider
// slot proves it was built with that backend (or fail the suite).
func (s *Suite) verifyKVBackendExpectation() error {
	expected, err := ResolveExpectedKVBackend(s.Config.ExpectKVBackend)
	if err != nil {
		return err
	}
	if expected == "" {
		return nil
	}
	return VerifyRegistryKVBackends(
		s.Ctx, s.Coordinator.Registry, expected, kvExpectationTimeout, s.Logger)
}

// kvSlotTarget is one (provider, model) pair the assertion must observe.
type kvSlotTarget struct {
	providerID string
	model      string
}

func (t kvSlotTarget) String() string { return t.providerID + "/" + t.model }

// VerifyRegistryKVBackends asserts that every model advertised by every
// registered provider is served by an engine slot whose heartbeat-reported
// `kv_backend` equals expected.
//
// Mechanics: collect the (provider, advertised model) pairs, push a
// `load_model` to each so lazily-loading providers construct their engines
// now (send errors are logged, not fatal — the assertion is the observation,
// not the push), then poll the registry's per-slot record until every pair
// reports. A pair that reports a DIFFERENT backend fails immediately, with
// the engine's own fallback-reason class (kill_switch, kernel_preflight,
// physical_capacity, ...) in the error so the log names WHY the build
// degraded. Pairs still unobserved at the deadline fail with the full
// pending list: "could not verify" is a failure, because the lane declared
// an expectation and green-without-proof is the exact pattern this exists
// to end.
func VerifyRegistryKVBackends(
	ctx context.Context,
	reg *registry.Registry,
	expected string,
	timeout time.Duration,
	logger *slog.Logger,
) error {
	if expected != KVBackendPaged && expected != KVBackendContiguous {
		return fmt.Errorf("unassertable expected KV backend %q", expected)
	}

	var targets []kvSlotTarget
	reg.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		for _, m := range p.Models {
			if m.ID != "" {
				targets = append(targets, kvSlotTarget{providerID: p.ID, model: m.ID})
			}
		}
		p.Mu().Unlock()
	})
	sort.Slice(targets, func(i, j int) bool { return targets[i].String() < targets[j].String() })
	if len(targets) == 0 {
		return fmt.Errorf(
			"KV backend expectation %q declared but no provider advertises any model — nothing to assert",
			expected)
	}

	logger.Info("verifying built KV backend",
		"expected", expected, "slots", len(targets), "timeout", timeout)

	// Pre-warm: a fresh testbed provider loads lazily, and an engine that was
	// never constructed reports nothing. Fire-and-forget by design; a
	// provider that cannot load will simply never report and the deadline
	// below converts that into a failure that names it.
	for _, t := range targets {
		if err := reg.SendLoadModel(t.providerID, t.model); err != nil {
			logger.Warn("kv-backend pre-warm load_model send failed",
				"provider_id", t.providerID, "model", t.model, "error", err)
		}
	}

	deadline := time.Now().Add(timeout)
	pending := targets
	for {
		var stillPending []kvSlotTarget
		for _, t := range pending {
			backend, fallback := reg.SlotKVBackendTags(t.providerID, t.model)
			switch backend {
			case expected:
				logger.Info("built KV backend verified",
					"provider_id", t.providerID, "model", t.model, "kv_backend", backend)
			case registry.KVBackendUnknown:
				// No heartbeat has named this slot yet — keep waiting.
				stillPending = append(stillPending, t)
			default:
				return fmt.Errorf(
					"provider %s built kv_backend=%q for %s (fallback reason class: %s); "+
						"this lane declares %s=%q — the engine under test is not the one "+
						"the lane claims to measure",
					t.providerID, backend, t.model, fallback, EnvExpectKVBackend, expected)
			}
		}
		if len(stillPending) == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			names := make([]string, len(stillPending))
			for i, t := range stillPending {
				names[i] = t.String()
			}
			return fmt.Errorf(
				"KV backend expectation %q unverified after %v: no heartbeat named a backend "+
					"for [%s]. Either the pre-warm load failed (an explicit-paged build REFUSES "+
					"instead of degrading — check the provider log for pagedUnavailable), the "+
					"model never loaded, or the provider predates per-slot kv_backend reporting",
				expected, timeout, strings.Join(names, ", "))
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("KV backend expectation %q interrupted: %w", expected, ctx.Err())
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// PrewarmRegistrySlot sends the production load_model command and waits for
// the exact provider/model slot to report a usable idle capacity heartbeat.
// The caller chooses the timeout because model size and runner storage speed
// dominate this wait. probeLoadFailure may inspect provider-owned state for a
// terminal load error; SendLoadModel is intentionally not a warm-pool
// reservation, so its load_model_status reply is not the completion signal.
func PrewarmRegistrySlot(
	ctx context.Context,
	reg *registry.Registry,
	providerID, model, expectedBackend string,
	timeout time.Duration,
	logger *slog.Logger,
	probeLoadFailure func() error,
) error {
	return prewarmRegistrySlot(
		ctx, reg, providerID, model, expectedBackend, timeout, logger,
		reg.SendLoadModel, probeLoadFailure)
}

type prewarmSlotObservation struct {
	present          bool
	state            string
	numRunning       int
	numWaiting       int
	maxConcurrency   int
	activeBudgetMax  int64
	backend          string
	fallback         string
	pendingModelLoad bool
}

func prewarmRegistrySlot(
	ctx context.Context,
	reg *registry.Registry,
	providerID, model, expectedBackend string,
	timeout time.Duration,
	logger *slog.Logger,
	sendLoadModel func(string, string) error,
	probeLoadFailure func() error,
) error {
	if expectedBackend != KVBackendPaged && expectedBackend != KVBackendContiguous {
		return fmt.Errorf("unassertable expected KV backend %q", expectedBackend)
	}
	if timeout <= 0 {
		return fmt.Errorf("pre-warm timeout must be positive, got %v", timeout)
	}
	if logger == nil {
		logger = slog.Default()
	}
	if err := sendLoadModel(providerID, model); err != nil {
		return fmt.Errorf(
			"send production load_model for exact slot %s/%s: %w (inspect provider stdout/stderr)",
			providerID, model, err)
	}
	logger.Info("waiting for pre-warmed provider slot",
		"provider_id", providerID, "model", model,
		"expected_kv_backend", expectedBackend, "timeout", timeout)

	deadline := time.Now().Add(timeout)
	var last prewarmSlotObservation
	for {
		if probeLoadFailure != nil {
			if err := probeLoadFailure(); err != nil {
				return fmt.Errorf(
					"provider failed production load_model for exact slot %s/%s: %w "+
						"(inspect provider stdout/stderr)",
					providerID, model, err)
			}
		}
		observation, err := observeRegistrySlot(reg, providerID, model)
		if err != nil {
			return err
		}
		last = observation
		if observation.present &&
			observation.state == "idle" &&
			observation.numRunning == 0 &&
			observation.numWaiting == 0 &&
			observation.maxConcurrency > 0 &&
			observation.activeBudgetMax > 0 &&
			observation.backend == expectedBackend &&
			!observation.pendingModelLoad {
			logger.Info("pre-warmed provider slot ready",
				"provider_id", providerID, "model", model,
				"kv_backend", observation.backend,
				"max_concurrency", observation.maxConcurrency,
				"active_token_budget_max", observation.activeBudgetMax)
			return nil
		}
		if observation.present &&
			observation.backend != "" &&
			observation.backend != expectedBackend {
			return fmt.Errorf(
				"provider %s built exact slot %s with kv_backend=%q, want %q "+
					"(fallback reason class: %s)",
				providerID, model, observation.backend, expectedBackend, observation.fallback)
		}
		if observation.present && observation.state == "crashed" {
			return fmt.Errorf(
				"provider %s exact slot %s reported state=%q after load_model "+
					"(inspect provider stdout/stderr and daemon-state load_error)",
				providerID, model, observation.state)
		}

		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf(
				"pre-warm exact slot %s/%s not ready after %v: "+
					"present=%t state=%q running=%d waiting=%d max_concurrency=%d "+
					"active_token_budget_max=%d kv_backend=%q fallback=%q pending_load=%t "+
					"(inspect provider stdout/stderr and daemon-state load_error)",
				providerID, model, timeout, last.present, last.state,
				last.numRunning, last.numWaiting, last.maxConcurrency,
				last.activeBudgetMax, last.backend, last.fallback, last.pendingModelLoad)
		}
		poll := 250 * time.Millisecond
		if remaining < poll {
			poll = remaining
		}
		timer := time.NewTimer(poll)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return fmt.Errorf("pre-warm exact slot %s/%s interrupted: %w",
				providerID, model, ctx.Err())
		case <-timer.C:
		}
	}
}

func observeRegistrySlot(
	reg *registry.Registry, providerID, model string,
) (prewarmSlotObservation, error) {
	p := reg.GetProvider(providerID)
	if p == nil {
		return prewarmSlotObservation{}, fmt.Errorf(
			"provider %q disconnected while pre-warming exact slot %q", providerID, model)
	}

	var observation prewarmSlotObservation
	p.Mu().Lock()
	if p.BackendCapacity != nil {
		for i := range p.BackendCapacity.Slots {
			slot := p.BackendCapacity.Slots[i]
			if slot.Model != model {
				continue
			}
			observation = observationFromBackendSlot(slot)
			break
		}
	}
	p.Mu().Unlock()
	observation.pendingModelLoad = reg.HasPendingModelLoad(providerID, model)
	return observation, nil
}

func observationFromBackendSlot(slot protocol.BackendSlotCapacity) prewarmSlotObservation {
	observation := prewarmSlotObservation{
		present:         true,
		state:           slot.State,
		numRunning:      slot.NumRunning,
		numWaiting:      slot.NumWaiting,
		maxConcurrency:  slot.MaxConcurrency,
		activeBudgetMax: slot.ActiveTokenBudgetMax,
	}
	if slot.KVBackend != nil {
		observation.backend = *slot.KVBackend
	}
	if slot.KVBackendFallbackReason != nil {
		observation.fallback = registry.KVBackendFallbackTag(
			*slot.KVBackendFallbackReason, true)
	}
	return observation
}
