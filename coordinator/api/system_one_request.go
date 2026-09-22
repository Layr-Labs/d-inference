package api

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	systemOneEndpoint     = "/v1/systemone"
	maxSystemOneBodyBytes = 1 << 20
	maxSystemOneQuestions = 64
	// Laya truncates state within each compiled encoder row. Instructions and
	// criteria must fit; the provider validates that tokenizer-dependent bound.
	systemOneTokensPerQuestion = 512
)

func isStructuredText(value any) bool {
	switch value.(type) {
	case string, map[string]any, []any:
		return true
	default:
		return false
	}
}

func validateSystemOneRequest(parsed map[string]any) (int, error) {
	if !isStructuredText(parsed["state"]) {
		return 0, fmt.Errorf("state must be a string, object, or array")
	}
	if stream, exists := parsed["stream"]; exists && stream != false {
		return 0, fmt.Errorf("SystemOne supports only non-streaming requests")
	}
	for _, name := range []string{"messages", "input", "prompt", "tools", "tool_choice", "max_tokens", "max_output_tokens", "max_completion_tokens", "temperature", "top_p", "top_k", "stop", "n", "response_format"} {
		if _, exists := parsed[name]; exists {
			return 0, fmt.Errorf("%s is not supported by SystemOne", name)
		}
	}
	questions, ok := parsed["questions"].(map[string]any)
	if !ok || len(questions) == 0 || len(questions) > maxSystemOneQuestions {
		return 0, fmt.Errorf("questions must be an object with 1 to %d entries", maxSystemOneQuestions)
	}
	for _, value := range questions {
		question, ok := value.(map[string]any)
		if !ok || !isStructuredText(question["instructions"]) {
			return 0, fmt.Errorf("each question requires instructions as a string, object, or array")
		}
		switch question["type"] {
		case "choice":
			criteria, ok := question["criteria"].(map[string]any)
			if !ok || len(criteria) < 1 || len(criteria) > 255 {
				return 0, fmt.Errorf("choice criteria must be an object with 1 to 255 options")
			}
			for _, description := range criteria {
				if description != nil && !isStructuredText(description) {
					return 0, fmt.Errorf("choice descriptions must be strings, objects, arrays, or null")
				}
			}
		case "score":
			criteria, ok := question["criteria"].([]any)
			if !ok || len(criteria) < 2 || len(criteria) > 10 {
				return 0, fmt.Errorf("score criteria must contain 2 to 10 levels")
			}
			for _, description := range criteria {
				if !isStructuredText(description) {
					return 0, fmt.Errorf("score descriptions must be strings, objects, or arrays")
				}
			}
		case "noul":
			if question["criteria"] != nil {
				criteria, ok := question["criteria"].(map[string]any)
				if !ok {
					return 0, fmt.Errorf("noul criteria must be an object")
				}
				for name, description := range criteria {
					if (name != "true" && name != "false") || !isStructuredText(description) {
						return 0, fmt.Errorf("noul criteria supports true and false descriptions as strings, objects, or arrays")
					}
				}
			}
		default:
			return 0, fmt.Errorf("question type must be choice, score, or noul")
		}
	}
	return len(questions), nil
}

// Construct only the native fields, retaining nested JSON key order. Option
// order and structured state order enter Laya's encoder prompt; round-tripping
// these values through map[string]any would silently change model input.
func systemOneProviderBody(original []byte, model string) ([]byte, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(original, &fields); err != nil {
		return nil, err
	}
	modelJSON, err := json.Marshal(model)
	if err != nil {
		return nil, err
	}
	return marshalForwardBody(map[string]json.RawMessage{
		"model":     modelJSON,
		"endpoint":  json.RawMessage(`"/v1/systemone"`),
		"state":     fields["state"],
		"questions": fields["questions"],
	})
}

func systemOneQuestionContract(parsed map[string]any) map[string]registry.SystemOneQuestion {
	questions := parsed["questions"].(map[string]any)
	specs := make(map[string]registry.SystemOneQuestion, len(questions))
	for id, value := range questions {
		q := value.(map[string]any)
		spec := registry.SystemOneQuestion{Type: q["type"].(string)}
		switch spec.Type {
		case "choice":
			criteria := q["criteria"].(map[string]any)
			spec.Options = make(map[string]struct{}, len(criteria))
			for option := range criteria {
				spec.Options[option] = struct{}{}
			}
		case "score":
			spec.Levels = len(q["criteria"].([]any))
			spec.Legend = q["criteria"].([]any)
		}
		specs[id] = spec
	}
	return specs
}
