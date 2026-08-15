package api

const serviceReasoningOptInModel = "qwen3.6-35b-a3b-vl-mtp-mxfp8"

// applyResolvedModelReasoningPolicy makes reasoning opt-in for service traffic
// to the Qwen build. Gemma defaults thinking off, while the production Qwen
// template defaults it on when reasoning is absent.
func applyResolvedModelReasoningPolicy(
	parsed map[string]any,
	rawBody []byte,
	resolvedModel string,
	serviceConsumer bool,
	reasoningProvided bool,
) ([]byte, bool, error) {
	if reasoningProvided {
		return rawBody, false, nil
	}

	_, hasReasoning := parsed["reasoning"]
	shouldDisable := serviceConsumer && resolvedModel == serviceReasoningOptInModel
	if hasReasoning == shouldDisable {
		return rawBody, false, nil
	}

	updated := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		updated[key] = value
	}
	if shouldDisable {
		updated["reasoning"] = map[string]any{"enabled": false}
	} else {
		delete(updated, "reasoning")
	}

	body, err := marshalForwardBody(updated)
	if err != nil {
		return rawBody, false, err
	}
	if shouldDisable {
		parsed["reasoning"] = updated["reasoning"]
	} else {
		delete(parsed, "reasoning")
	}
	return body, true, nil
}
