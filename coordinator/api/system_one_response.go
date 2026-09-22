package api

import (
	"context"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// parseSystemOneResponse recognizes valid decision content for egress evidence.
// Ingress also supplies the request's ephemeral answer contract.
func parseSystemOneResponse(data []byte) (map[string]any, bool) {
	return validateSystemOneResponse(data, nil)
}

func validateSystemOneResponse(data []byte, expected map[string]registry.SystemOneQuestion) (map[string]any, bool) {
	response, err := decodeInferenceJSONObject(data)
	if err != nil {
		return nil, false
	}
	answers, ok := response["answers"].(map[string]any)
	if !ok || len(answers) == 0 || (expected != nil && len(answers) != len(expected)) {
		return nil, false
	}
	cleanAnswers := make(map[string]any, len(answers))
	for id, value := range answers {
		answer, ok := value.(map[string]any)
		if !ok {
			return nil, false
		}
		kind, ok := answer["type"].(string)
		if !ok {
			return nil, false
		}
		spec, known := expected[id]
		if expected != nil && (!known || spec.Type != kind) {
			return nil, false
		}
		confidence, ok := probability(answer["confidence"])
		if !ok {
			return nil, false
		}
		action, ok := answer["action"].(map[string]any)
		if !ok {
			return nil, false
		}
		act, ok := probability(action["act_probability"])
		if !ok {
			return nil, false
		}
		clean := map[string]any{"type": kind, "confidence": confidence, "action": map[string]any{"act_probability": act}}
		switch kind {
		case "noul":
			noul, ok := probability(answer["noul"])
			if !ok {
				return nil, false
			}
			clean["noul"] = noul
		case "choice":
			choice, ok := answer["choice"].(string)
			if !ok {
				return nil, false
			}
			probs, ok := systemOneProbabilities(answer["probabilities"])
			if !ok {
				return nil, false
			}
			chosen, exists := probs[choice]
			if !exists {
				return nil, false
			}
			if expected != nil && len(probs) != len(spec.Options) {
				return nil, false
			}
			for option, value := range probs {
				if expected != nil {
					if _, ok := spec.Options[option]; !ok {
						return nil, false
					}
				}
				valueN, _ := probability(value)
				chosenN, _ := probability(chosen)
				if valueN > chosenN+1e-6 {
					return nil, false
				}
			}
			clean["choice"], clean["probabilities"] = choice, probs
		case "score":
			score, ok := nativeNumber(answer["score"])
			if !ok {
				return nil, false
			}
			probs, ok := systemOneProbabilities(answer["probabilities"])
			if !ok || len(probs) < 2 || len(probs) > 10 {
				return nil, false
			}
			legend, ok := answer["legend"].(map[string]any)
			if !ok || len(legend) != len(probs) {
				return nil, false
			}
			if expected != nil && len(probs) != spec.Levels {
				return nil, false
			}
			weighted := 0.0
			for i := 0; i < len(probs); i++ {
				key := strconv.Itoa(i)
				p, ok := probability(probs[key])
				if !ok {
					return nil, false
				}
				if !isStructuredText(legend[key]) {
					return nil, false
				}
				if expected != nil && (len(spec.Legend) != len(probs) || !systemOneJSONEqual(legend[key], spec.Legend[i])) {
					return nil, false
				}
				weighted += float64(i) * p
			}
			if math.IsNaN(score) || math.IsInf(score, 0) || score < 0 || score > float64(len(probs)-1) || math.Abs(score-weighted) > systemOneScoreRoundingTolerance(len(probs)) {
				return nil, false
			}
			clean["score"], clean["probabilities"], clean["legend"] = score, probs, legend
		default:
			return nil, false
		}
		cleanAnswers[id] = clean
	}
	return map[string]any{"answers": cleanAnswers}, true
}

func (s *Server) writeSystemOneResponse(ctx context.Context, w http.ResponseWriter, pr *registry.PendingRequest, chunks []string) {
	if len(chunks) != 1 {
		writeJSON(w, 502, errorResponse("provider_error", "expected one native decision response"))
		return
	}
	response, valid := validateSystemOneResponse([]byte(strings.TrimPrefix(chunks[0], "data: ")), pr.SystemOneQuestions)
	if !valid {
		writeJSON(w, 502, errorResponse("provider_error", "invalid native decision response"))
		return
	}
	usage, ok := s.awaitNonStreamUsage(ctx, w, pr)
	if !ok {
		return
	}
	if usage.PromptTokens <= 0 || usage.CompletionTokens != 0 {
		writeJSON(w, 502, errorResponse("provider_error", "invalid native decision usage"))
		return
	}
	response["model"] = consumerModel(pr)
	response["usage"] = map[string]any{"input_tokens": usage.PromptTokens, "output_tokens": 0}
	addResponseProof(response, pr)
	s.noteInferenceSuccess(pr)
	writeNonStreamBody(w, pr.Profile.Parent(), response)
}
