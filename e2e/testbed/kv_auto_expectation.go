package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Native auto may legitimately resolve either storage backend after the
// provider's model policy, capability vetoes and observable fallback. This
// private expectation still requires a real, usable slot and a concrete tag.
const nativeAutoBackend = "native_auto"

// EnvKVQuantization is the provider's public precision selector. Forward it
// through the explicit launch spec so an owned host and a local child use
// the same precision that automatic benchmark prewarm checks.
const EnvKVQuantization = "DARKBLOOM_CBV2_KV_QUANTIZATION"

func automaticBackendExpectation(modelType, precision string) (string, error) {
	// Match the provider's unconditional SDK MiMo exclusion before parsing an
	// override. Use actual registration metadata, never an artifact-ID list.
	if modelType == "mimo_v2" {
		return KVBackendContiguous, nil
	}
	if modelType == "" {
		return "", fmt.Errorf("automatic KV prewarm requires registered model_type")
	}
	switch strings.ToLower(strings.TrimSpace(precision)) {
	case "", "balanced", "k4v4", "int4", "on", "k8v4", "k8v8", "int8":
		return KVBackendPaged, nil
	case "native", "off", "0":
		return nativeAutoBackend, nil
	default:
		return "", fmt.Errorf("invalid KV precision %q for automatic benchmark prewarm", precision)
	}
}

func verifyAutomaticRegistryKVBackends(
	ctx context.Context, reg *registry.Registry, precision string, timeout time.Duration,
	logger *slog.Logger, sendLoadModel func(string, string) error,
) error {
	type target struct {
		providerID, model, modelType string
		expected                     string
		autopilot                    bool
	}
	var targets []target
	reg.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		for _, model := range p.Models {
			if model.ID != "" {
				targets = append(targets, target{
					providerID: p.ID, model: model.ID, modelType: model.ModelType,
					autopilot: p.ModelAutopilot != nil && p.ModelAutopilot.Enabled,
				})
			}
		}
	})
	if len(targets) == 0 {
		return fmt.Errorf("automatic KV benchmark prewarm has no advertised model slots")
	}
	if timeout <= 0 {
		return fmt.Errorf("automatic KV prewarm timeout must be positive, got %v", timeout)
	}
	if logger == nil {
		logger = slog.Default()
	}
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].providerID+"/"+targets[i].model < targets[j].providerID+"/"+targets[j].model
	})
	for i := range targets {
		expected, err := automaticBackendExpectation(targets[i].modelType, precision)
		if err != nil {
			return fmt.Errorf("automatic KV prewarm %s/%s: %w", targets[i].providerID, targets[i].model, err)
		}
		targets[i].expected = expected
	}
	deadline := time.Now().Add(timeout)
	for _, slot := range targets {
		logger.Info("verifying automatic KV backend policy",
			"provider_id", slot.providerID, "model", slot.model,
			"model_type", slot.modelType, "kv_precision", precision, "expected", slot.expected)
		prewarm := sendLoadModel
		if slot.autopilot {
			// Its controller owns residency. Keep the same heartbeat/readiness
			// proof without issuing the legacy load command.
			prewarm = func(string, string) error { return nil }
		}
		if err := prewarmRegistrySlot(ctx, reg, slot.providerID, slot.model, slot.expected,
			time.Until(deadline), logger, prewarm, nil); err != nil {
			return err
		}
	}
	// Loading another model may evict an earlier one. All declared targets
	// must still be usable together when the measured topology starts.
	for _, slot := range targets {
		observation, err := observeRegistrySlot(reg, slot.providerID, slot.model)
		if err != nil {
			return err
		}
		if !observation.isReady(slot.expected) {
			return fmt.Errorf("automatic KV prewarm slot %s/%s lost usable capacity before measurement: "+
				"state=%q kv_backend=%q active_token_budget_max=%d pending_load=%t",
				slot.providerID, slot.model, observation.state, observation.backend,
				observation.activeBudgetMax, observation.pendingModelLoad)
		}
	}
	return nil
}
