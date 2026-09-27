package api

const serviceReasoningOptInModel = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

// applyResolvedModelReasoningPolicy makes reasoning opt-in for service traffic
// to the Qwen build. Gemma defaults thinking off, while the production Qwen
// template defaults it on when reasoning is absent. It mutates parsed in place
// and reports whether it did, so the caller marks its forward body dirty; it
// is idempotent for a given resolved model, which lets the per-request body
// memo reuse the handler's own serialization for that model.
func applyResolvedModelReasoningPolicy(
	parsed map[string]any,
	resolvedModel string,
	serviceConsumer bool,
	reasoningProvided bool,
) (changed bool) {
	if reasoningProvided {
		return false
	}

	_, hasReasoning := parsed["reasoning"]
	shouldDisable := serviceConsumer && resolvedModel == serviceReasoningOptInModel
	if hasReasoning == shouldDisable {
		return false
	}
	if shouldDisable {
		parsed["reasoning"] = map[string]any{"enabled": false}
	} else {
		delete(parsed, "reasoning")
	}
	return true
}
