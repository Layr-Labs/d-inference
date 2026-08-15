package api

import (
	"log/slog"
	"strings"
)

const serviceReasoningOptInModel = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

// applyResolvedModelReasoningPolicy makes reasoning opt-in for service traffic
// to the Qwen build. Gemma defaults thinking off, while the production Qwen
// template defaults it on when reasoning is absent.
//
// OpenRouter does not forward the OpenRouter-style `reasoning` object to us,
// but it does forward the OpenAI-style top-level `reasoning_effort` string, so
// when `reasoning` is absent that string carries the caller's intent: absent
// or "none" keeps thinking off, any other non-empty value turns it on.
func applyResolvedModelReasoningPolicy(
	parsed map[string]any,
	rawBody []byte,
	resolvedModel string,
	serviceConsumer bool,
	reasoningProvided bool,
	reasoningEffort string,
) ([]byte, bool, error) {
	if reasoningProvided {
		return rawBody, false, nil
	}

	_, hasReasoning := parsed["reasoning"]
	shouldInject := serviceConsumer && resolvedModel == serviceReasoningOptInModel
	if hasReasoning == shouldInject {
		return rawBody, false, nil
	}

	updated := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		updated[key] = value
	}
	if shouldInject {
		updated["reasoning"] = map[string]any{
			"enabled": reasoningEffortRequestsThinking(reasoningEffort),
		}
	} else {
		delete(updated, "reasoning")
	}

	body, err := marshalForwardBody(updated)
	if err != nil {
		return rawBody, false, err
	}
	if shouldInject {
		parsed["reasoning"] = updated["reasoning"]
	} else {
		delete(parsed, "reasoning")
	}
	return body, true, nil
}

// reasoningEffortRequestsThinking maps a top-level reasoning_effort string to
// a thinking intent: absent/blank/"none" means off, anything else means on.
func reasoningEffortRequestsThinking(effort string) bool {
	normalized := strings.ToLower(strings.TrimSpace(effort))
	return normalized != "" && normalized != "none"
}

// logServiceReasoningShape emits one privacy-safe observability line per
// service chat request that resolved to the reasoning-opt-in model, BEFORE the
// policy mutates parsed, so we can see which reasoning intent shape OpenRouter
// actually forwards. Only presence bits, booleans, and closed-set enums are
// logged — never request content.
func logServiceReasoningShape(logger *slog.Logger, parsed map[string]any, model string) {
	reasoning, reasoningPresent := parsed["reasoning"]

	var reasoningEnabled any = "absent"
	if reasoningPresent {
		reasoningEnabled = "non_bool"
		if object, ok := reasoning.(map[string]any); ok {
			if enabled, ok := object["enabled"].(bool); ok {
				reasoningEnabled = enabled
			}
		}
	}

	effort := "absent"
	if raw, present := parsed["reasoning_effort"]; present {
		effort = "other"
		if value, ok := raw.(string); ok {
			switch normalized := strings.ToLower(strings.TrimSpace(value)); normalized {
			case "none", "minimal", "low", "medium", "high", "xhigh", "max":
				effort = normalized
			}
		}
	}

	injected := "none"
	if !reasoningPresent {
		if reasoningEffortRequestsThinking(effortString(parsed)) {
			injected = "true"
		} else {
			injected = "false"
		}
	}

	logger.Info("service reasoning shape",
		"model", model,
		"reasoning_present", reasoningPresent,
		"reasoning_enabled", reasoningEnabled,
		"reasoning_effort", effort,
		"injected", injected,
	)
}

// effortString extracts the top-level reasoning_effort as a string; non-string
// values read as absent, matching the injection policy's view.
func effortString(parsed map[string]any) string {
	effort, _ := parsed["reasoning_effort"].(string)
	return effort
}
