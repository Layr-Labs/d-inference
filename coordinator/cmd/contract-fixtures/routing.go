package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
)

type routingProviderContract struct {
	ID                      string `json:"id"`
	DecodeMilliTPS          int    `json:"decode_milli_tps"`
	EffectiveDecodeMilliTPS int    `json:"effective_decode_milli_tps"`
}

type routingCapacityContract struct {
	TokenCapacity   int `json:"token_capacity"`
	KVCapacityBytes int `json:"kv_capacity_bytes"`
	Concurrency     int `json:"concurrency_limit"`
	KVBytesPerToken int `json:"kv_bytes_per_token"`
}

type routingDeadlineContract struct {
	BaseMicroseconds           int64 `json:"base_microseconds"`
	PerPromptTokenMicroseconds int64 `json:"per_prompt_token_microseconds"`
}

type routingRunContract[T comparable] struct {
	Count int `json:"count"`
	Value T   `json:"value"`
}

type routingScenarioContract struct {
	Name                              string                       `json:"name"`
	PrefillToDecodeRatioMilli         int                          `json:"prefill_to_decode_ratio_milli"`
	SoftTTFTGate                      bool                         `json:"soft_ttft_gate"`
	BestTTFTMicroseconds              []int64                      `json:"best_ttft_microseconds"`
	HasTTFTRuns                       []routingRunContract[bool]   `json:"has_ttft_runs"`
	ExpectedOutcomeRuns               []routingRunContract[string] `json:"expected_outcome_runs"`
	CandidateCountRuns                []routingRunContract[int]    `json:"candidate_count_runs"`
	CapacityRejectionRuns             []routingRunContract[int]    `json:"capacity_rejection_runs"`
	ExpectedStableRankFirstProviderID []routingRunContract[string] `json:"expected_stable_rank_first_provider_id_runs"`
}

type routingScoringCandidateContract struct {
	GoProviderID                    string `json:"go_provider_id"`
	CoreProviderID                  string `json:"core_provider_id"`
	PredictedTTFTMicroseconds       int64  `json:"predicted_ttft_microseconds"`
	RequestPrefillMicroseconds      int64  `json:"request_prefill_microseconds"`
	CompletionTokens                int    `json:"completion_tokens"`
	DecodeMilliTPS                  int    `json:"decode_milli_tps"`
	QuotedMicroUSD                  int    `json:"quoted_micro_usd"`
	QueueDepth                      int    `json:"queue_depth"`
	StatePenaltyMicroseconds        int64  `json:"state_penalty_microseconds"`
	PendingPenaltyMicroseconds      int64  `json:"pending_penalty_microseconds"`
	BacklogPenaltyMicroseconds      int64  `json:"backlog_penalty_microseconds"`
	HealthPenaltyMicroseconds       int64  `json:"health_penalty_microseconds"`
	CapacityRatePenaltyMicroseconds int64  `json:"capacity_rate_penalty_microseconds"`
}

type routingGoScoringDecisionContract struct {
	TotalMicroseconds        int64 `json:"total_microseconds"`
	StateMicroseconds        int64 `json:"state_microseconds"`
	QueueMicroseconds        int64 `json:"queue_microseconds"`
	PendingMicroseconds      int64 `json:"pending_microseconds"`
	BacklogMicroseconds      int64 `json:"backlog_microseconds"`
	ThisRequestMicroseconds  int64 `json:"this_request_microseconds"`
	HealthMicroseconds       int64 `json:"health_microseconds"`
	CapacityRateMicroseconds int64 `json:"capacity_rate_microseconds"`
	EffectiveDecodeMilliTPS  int64 `json:"effective_decode_milli_tps"`
	EffectiveQueue           int   `json:"effective_queue"`
	CandidateCount           int   `json:"candidate_count"`
	TTFTMicroseconds         int64 `json:"ttft_microseconds"`
}

type routingScoringCaseContract struct {
	Name                                     string                            `json:"name"`
	PromptTokens                             int                               `json:"prompt_tokens"`
	PrefillToDecodeRatioMilli                int                               `json:"prefill_to_decode_ratio_milli"`
	MicrosecondsPerMicroUSD                  int                               `json:"microseconds_per_micro_usd"`
	QueuePenaltyMicroseconds                 int                               `json:"queue_penalty_microseconds"`
	Candidates                               []routingScoringCandidateContract `json:"candidates"`
	ActualSelectedProviderIndex              int                               `json:"actual_selected_provider_index"`
	ActualSelectedProviderID                 string                            `json:"actual_selected_provider_id"`
	GoDecision                               routingGoScoringDecisionContract  `json:"go_decision"`
	ExpectedRustThisRequestDeltaMicroseconds int64                             `json:"expected_rust_this_request_delta_microseconds"`
	ExpectedRustTotalDeltaMicroseconds       int64                             `json:"expected_rust_total_delta_microseconds"`
}

type routingContractFile struct {
	SchemaVersion       int                          `json:"schema_version"`
	Model               string                       `json:"model"`
	PromptData          string                       `json:"prompt_data"`
	PromptTokens        []int                        `json:"prompt_tokens"`
	MaxCompletionTokens int                          `json:"max_completion_tokens"`
	Deadline            routingDeadlineContract      `json:"deadline"`
	Capacity            routingCapacityContract      `json:"capacity"`
	Providers           []routingProviderContract    `json:"providers"`
	Scenarios           []routingScenarioContract    `json:"scenarios"`
	ScoringCases        []routingScoringCaseContract `json:"scoring_cases"`
}

func routingRLE[T comparable](values []T) []routingRunContract[T] {
	if len(values) == 0 {
		return nil
	}
	runs := make([]routingRunContract[T], 0, 4)
	current := values[0]
	count := 1
	for _, value := range values[1:] {
		if value == current {
			count++
			continue
		}
		runs = append(runs, routingRunContract[T]{Count: count, Value: current})
		current = value
		count = 1
	}
	return append(runs, routingRunContract[T]{Count: count, Value: current})
}

func routingCeilDiv(numerator, denominator int64) int64 {
	return (numerator + denominator - 1) / denominator
}

func routingScoringPrefillMicroseconds(promptTokens, ratioMilli, decodeMilliTPS int) int64 {
	return routingCeilDiv(
		int64(promptTokens)*1_000_000_000_000,
		int64(decodeMilliTPS)*int64(ratioMilli),
	)
}

func routingScoringTTFTMicroseconds(promptTokens, ratioMilli, decodeMilliTPS int) int64 {
	prefill := routingScoringPrefillMicroseconds(promptTokens, ratioMilli, decodeMilliTPS)
	firstDecode := routingCeilDiv(1_000_000_000, int64(decodeMilliTPS))
	return prefill + firstDecode
}

func routingMillisecondsToMicroseconds(milliseconds float64) int64 {
	return int64(math.Round(milliseconds * 1000))
}

func generateRoutingScoringCases(model string) ([]routingScoringCaseContract, error) {
	const ratioMilli = 12_000
	specs := []struct {
		name             string
		promptTokens     int
		completionTokens int
		decodeTPS        []int
	}{
		{
			name: "decode_rates_fast_last", promptTokens: 256, completionTokens: 256,
			decodeTPS: []int{12, 30, 60},
		},
		{
			name: "decode_rates_fast_first", promptTokens: 512, completionTokens: 128,
			decodeTPS: []int{120, 10, 30},
		},
	}

	registry.SetPrefillToDecodeRatio(float64(ratioMilli) / 1000)
	cases := make([]routingScoringCaseContract, 0, len(specs))
	for caseIndex, spec := range specs {
		prefix := fmt.Sprintf("score-%d", caseIndex)
		fleet, err := routingsim.BuildFleet(nil, routingsim.FleetConfig{
			Model: model, Providers: len(spec.decodeTPS), WarmFraction: 1, IDPrefix: prefix,
			DecodeTPS: routingsim.DecodeTPSDist(func(index, _ int) float64 {
				return float64(spec.decodeTPS[index])
			}),
		})
		if err != nil {
			return nil, fmt.Errorf("build scoring fleet %s: %w", spec.name, err)
		}
		requestID := "contract-" + spec.name
		selected, decision := fleet.ReserveProviderEx(model, &registry.PendingRequest{
			RequestID: requestID, Model: model,
			EstimatedPromptTokens: spec.promptTokens, RequestedMaxTokens: spec.completionTokens,
		})
		if selected == nil {
			return nil, fmt.Errorf("scoring case %s selected no provider: %+v", spec.name, decision)
		}
		selected.RemovePending(requestID)
		fleet.SetProviderIdle(selected.ID)
		if decision.ProviderID != selected.ID || decision.CandidateCount != len(spec.decodeTPS) {
			return nil, fmt.Errorf("scoring case %s inconsistent decision: %+v", spec.name, decision)
		}
		if decision.StateMs != 0 || decision.QueueMs != 0 || decision.PendingMs != 0 ||
			decision.BacklogMs != 0 || decision.CapacityRateMs != 0 || decision.EffectiveQueue != 0 {
			return nil, fmt.Errorf(
				"scoring case %s is not idle/warm/queue-free: %+v",
				spec.name, decision,
			)
		}

		goDecision := routingGoScoringDecisionContract{
			TotalMicroseconds:        routingMillisecondsToMicroseconds(decision.CostMs),
			StateMicroseconds:        routingMillisecondsToMicroseconds(decision.StateMs),
			QueueMicroseconds:        routingMillisecondsToMicroseconds(decision.QueueMs),
			PendingMicroseconds:      routingMillisecondsToMicroseconds(decision.PendingMs),
			BacklogMicroseconds:      routingMillisecondsToMicroseconds(decision.BacklogMs),
			ThisRequestMicroseconds:  routingMillisecondsToMicroseconds(decision.ThisReqMs),
			HealthMicroseconds:       routingMillisecondsToMicroseconds(decision.HealthMs),
			CapacityRateMicroseconds: routingMillisecondsToMicroseconds(decision.CapacityRateMs),
			EffectiveDecodeMilliTPS:  int64(math.Round(decision.EffectiveTPS * 1000)),
			EffectiveQueue:           decision.EffectiveQueue,
			CandidateCount:           decision.CandidateCount,
			TTFTMicroseconds:         routingMillisecondsToMicroseconds(decision.TTFTMs),
		}
		componentTotal := goDecision.StateMicroseconds + goDecision.QueueMicroseconds +
			goDecision.PendingMicroseconds + goDecision.BacklogMicroseconds +
			goDecision.ThisRequestMicroseconds + goDecision.HealthMicroseconds +
			goDecision.CapacityRateMicroseconds
		if delta := componentTotal - goDecision.TotalMicroseconds; delta < -2 || delta > 2 {
			return nil, fmt.Errorf(
				"scoring case %s Go rounded components differ from total by %dµs",
				spec.name, delta,
			)
		}

		candidates := make([]routingScoringCandidateContract, 0, len(spec.decodeTPS))
		selectedIndex := -1
		for index, decodeTPS := range spec.decodeTPS {
			goProviderID := fmt.Sprintf("%s-%04d", prefix, index)
			if goProviderID == selected.ID {
				selectedIndex = index
			}
			decodeMilliTPS := decodeTPS * 1000
			candidates = append(candidates, routingScoringCandidateContract{
				GoProviderID:                    goProviderID,
				CoreProviderID:                  fmt.Sprintf("10000000-0000-4000-8000-%012x", caseIndex*100+index+1),
				PredictedTTFTMicroseconds:       routingScoringTTFTMicroseconds(spec.promptTokens, ratioMilli, decodeMilliTPS),
				RequestPrefillMicroseconds:      routingScoringPrefillMicroseconds(spec.promptTokens, ratioMilli, decodeMilliTPS),
				CompletionTokens:                spec.completionTokens,
				DecodeMilliTPS:                  decodeMilliTPS,
				QuotedMicroUSD:                  0,
				QueueDepth:                      0,
				StatePenaltyMicroseconds:        goDecision.StateMicroseconds,
				PendingPenaltyMicroseconds:      goDecision.PendingMicroseconds,
				BacklogPenaltyMicroseconds:      goDecision.BacklogMicroseconds,
				HealthPenaltyMicroseconds:       goDecision.HealthMicroseconds,
				CapacityRatePenaltyMicroseconds: goDecision.CapacityRateMicroseconds,
			})
		}
		if selectedIndex < 0 {
			return nil, fmt.Errorf("scoring case %s selected unknown provider %q", spec.name, selected.ID)
		}
		selectedCandidate := candidates[selectedIndex]
		if int64(selectedCandidate.DecodeMilliTPS) != goDecision.EffectiveDecodeMilliTPS {
			return nil, fmt.Errorf(
				"scoring case %s selected effective TPS drift: candidate=%d Go=%d",
				spec.name, selectedCandidate.DecodeMilliTPS, goDecision.EffectiveDecodeMilliTPS,
			)
		}
		rustThisRequestMicroseconds := selectedCandidate.RequestPrefillMicroseconds +
			routingCeilDiv(
				int64(selectedCandidate.CompletionTokens)*1_000_000_000,
				int64(selectedCandidate.DecodeMilliTPS),
			)
		rustTotalMicroseconds := selectedCandidate.StatePenaltyMicroseconds +
			selectedCandidate.PendingPenaltyMicroseconds +
			selectedCandidate.BacklogPenaltyMicroseconds +
			rustThisRequestMicroseconds +
			selectedCandidate.HealthPenaltyMicroseconds +
			selectedCandidate.CapacityRatePenaltyMicroseconds
		cases = append(cases, routingScoringCaseContract{
			Name:                                     spec.name,
			PromptTokens:                             spec.promptTokens,
			PrefillToDecodeRatioMilli:                ratioMilli,
			MicrosecondsPerMicroUSD:                  0,
			QueuePenaltyMicroseconds:                 0,
			Candidates:                               candidates,
			ActualSelectedProviderIndex:              selectedIndex,
			ActualSelectedProviderID:                 selected.ID,
			GoDecision:                               goDecision,
			ExpectedRustThisRequestDeltaMicroseconds: rustThisRequestMicroseconds - goDecision.ThisRequestMicroseconds,
			ExpectedRustTotalDeltaMicroseconds:       rustTotalMicroseconds - goDecision.TotalMicroseconds,
		})
	}
	return cases, nil
}

func generateRouting(_ string) (map[string][]byte, error) {
	const (
		model            = "mlx-community/Qwen3.5-9B-Instruct-4bit"
		providerCount    = 70
		perBucket        = 250
		maxTokens        = 512
		medianDecodeTPS  = 25
		decodeSpread     = 2
		tokenCapacity    = 16_384
		kvCapacityBytes  = 64 * 1024 * 1024
		concurrencyLimit = 8
		kvBytesPerToken  = 1024
		deadlineBaseUS   = int64(5_000_000)
		deadlinePerTokUS = int64(1_000)
	)
	oldCalibration, hadCalibration := os.LookupEnv("EIGENINFERENCE_TTFT_CALIBRATION")
	if err := os.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off"); err != nil {
		return nil, err
	}
	defer func() {
		if hadCalibration {
			_ = os.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", oldCalibration)
		} else {
			_ = os.Unsetenv("EIGENINFERENCE_TTFT_CALIBRATION")
		}
	}()

	trace := routingsim.GenerateTrace(model, maxTokens, routingsim.CalibrationPromptMix(perBucket))
	promptTokens := make([]int, len(trace))
	for index, arrival := range trace {
		if arrival.Model != model || arrival.MaxTokens != maxTokens {
			return nil, fmt.Errorf("routing trace arrival %d has inconsistent global inputs", index)
		}
		promptTokens[index] = arrival.PromptTokens
	}
	scenarioSpecs := []struct {
		name       string
		ratioMilli int
		softGate   bool
	}{
		{name: "legacy_ratio_hard_gate", ratioMilli: 4_000, softGate: false},
		{name: "calibrated_ratio_hard_gate", ratioMilli: 12_000, softGate: false},
		{name: "calibrated_ratio_soft_gate", ratioMilli: 12_000, softGate: true},
	}
	previousRatio := registry.PrefillToDecodeRatio()
	defer registry.SetPrefillToDecodeRatio(previousRatio)

	providerContracts := make([]routingProviderContract, 0, providerCount)
	period := 2*decodeSpread + 1
	stableRankFirst := ""
	bestDecodeMilliTPS := 0
	for i := 0; i < providerCount; i++ {
		decodeTPS := medianDecodeTPS + (i % period) - decodeSpread
		provider := routingProviderContract{
			ID:                      fmt.Sprintf("00000000-0000-4000-8000-%012x", i+1),
			DecodeMilliTPS:          decodeTPS * 1000,
			EffectiveDecodeMilliTPS: decodeTPS * 1000,
		}
		providerContracts = append(providerContracts, provider)
		if provider.DecodeMilliTPS > bestDecodeMilliTPS {
			bestDecodeMilliTPS = provider.DecodeMilliTPS
			stableRankFirst = provider.ID
		}
	}

	scenarios := make([]routingScenarioContract, 0, len(scenarioSpecs))
	for _, spec := range scenarioSpecs {
		registry.SetPrefillToDecodeRatio(float64(spec.ratioMilli) / 1000)
		fleet, err := routingsim.BuildFleet(nil, routingsim.FleetConfig{
			Model: model, Providers: providerCount, WarmFraction: 1,
			DecodeTPS: routingsim.ClusteredDecodeTPS(medianDecodeTPS, decodeSpread),
		})
		if err != nil {
			return nil, fmt.Errorf("build routing fleet for %s: %w", spec.name, err)
		}
		bestTTFTMicroseconds := make([]int64, 0, len(trace))
		hasTTFTValues := make([]bool, 0, len(trace))
		outcomes := make([]string, 0, len(trace))
		candidateCounts := make([]int, 0, len(trace))
		capacityRejectionValues := make([]int, 0, len(trace))
		stableRankFirstValues := make([]string, 0, len(trace))
		for index, arrival := range trace {
			candidates, capacityRejections, _, bestTTFT, hasTTFT :=
				fleet.QuickCapacityCheckWithTTFTForRequest(
					arrival.Model,
					arrival.PromptTokens,
					arrival.MaxTokens,
					registry.RequestTraits{},
					false,
				)
			deadline := routingsim.TTFTDeadline(arrival.PromptTokens)
			expectedDeadlineUS := deadlineBaseUS + int64(arrival.PromptTokens)*deadlinePerTokUS
			if deadline.Microseconds() != expectedDeadlineUS {
				return nil, fmt.Errorf(
					"routing deadline drift at arrival %d: got %dµs, constants produce %dµs",
					index, deadline.Microseconds(), expectedDeadlineUS,
				)
			}
			outcome := routingsim.OutcomeServed
			if candidates == 0 && capacityRejections > 0 {
				outcome = routingsim.OutcomeMachineBusy
			} else if !spec.softGate && hasTTFT && bestTTFT > deadline {
				outcome = routingsim.OutcomeTTFTTooSlow
			}
			bestTTFTUS := int64(0)
			if hasTTFT {
				bestTTFTUS = bestTTFT.Microseconds()
			}
			bestTTFTMicroseconds = append(bestTTFTMicroseconds, bestTTFTUS)
			hasTTFTValues = append(hasTTFTValues, hasTTFT)
			outcomes = append(outcomes, string(outcome))
			candidateCounts = append(candidateCounts, candidates)
			capacityRejectionValues = append(capacityRejectionValues, capacityRejections)
			stableRankFirstValues = append(stableRankFirstValues, stableRankFirst)
		}
		scenarios = append(scenarios, routingScenarioContract{
			Name:                              spec.name,
			PrefillToDecodeRatioMilli:         spec.ratioMilli,
			SoftTTFTGate:                      spec.softGate,
			BestTTFTMicroseconds:              bestTTFTMicroseconds,
			HasTTFTRuns:                       routingRLE(hasTTFTValues),
			ExpectedOutcomeRuns:               routingRLE(outcomes),
			CandidateCountRuns:                routingRLE(candidateCounts),
			CapacityRejectionRuns:             routingRLE(capacityRejectionValues),
			ExpectedStableRankFirstProviderID: routingRLE(stableRankFirstValues),
		})
	}
	scoringCases, err := generateRoutingScoringCases(model)
	if err != nil {
		return nil, err
	}
	contract, err := json.MarshalIndent(routingContractFile{
		SchemaVersion: 2, Model: model,
		PromptData:   "synthetic token counts only; no prompt or response content",
		PromptTokens: promptTokens, MaxCompletionTokens: maxTokens,
		Deadline: routingDeadlineContract{
			BaseMicroseconds: deadlineBaseUS, PerPromptTokenMicroseconds: deadlinePerTokUS,
		},
		Capacity: routingCapacityContract{
			TokenCapacity: tokenCapacity, KVCapacityBytes: kvCapacityBytes,
			Concurrency: concurrencyLimit, KVBytesPerToken: kvBytesPerToken,
		},
		Providers:    providerContracts,
		Scenarios:    scenarios,
		ScoringCases: scoringCases,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal routing contract: %w", err)
	}
	return map[string][]byte{"tests/contracts/routing/ttft_calibration.json": contract}, nil
}
