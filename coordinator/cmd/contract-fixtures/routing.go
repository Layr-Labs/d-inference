package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
)

type routingBucketContract struct {
	Label        string `json:"label"`
	Total        int    `json:"total"`
	Served       int    `json:"served"`
	MachineBusy  int    `json:"machine_busy"`
	TTFTTooSlow  int    `json:"ttft_too_slow"`
	OtherRejects int    `json:"other_rejects"`
}

type routingScenarioContract struct {
	Name                 string                  `json:"name"`
	PrefillToDecodeRatio float64                 `json:"prefill_to_decode_ratio"`
	SoftTTFTGate         bool                    `json:"soft_ttft_gate"`
	Total                int                     `json:"total"`
	Served               int                     `json:"served"`
	MachineBusy          int                     `json:"machine_busy"`
	TTFTTooSlow          int                     `json:"ttft_too_slow"`
	EstimatedCliff       int                     `json:"estimated_cliff_tokens"`
	Buckets              []routingBucketContract `json:"buckets"`
}

type routingContractFile struct {
	SchemaVersion int                       `json:"schema_version"`
	Model         string                    `json:"model"`
	Providers     int                       `json:"providers"`
	PromptData    string                    `json:"prompt_data"`
	Scenarios     []routingScenarioContract `json:"scenarios"`
}

func generateRouting(_ string) (map[string][]byte, error) {
	const (
		model     = "mlx-community/Qwen3.5-9B-Instruct-4bit"
		providers = 70
		perBucket = 250
		maxTokens = 512
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
	scenarioSpecs := []struct {
		name     string
		ratio    float64
		softGate bool
	}{
		{name: "legacy_ratio_hard_gate", ratio: 4, softGate: false},
		{name: "calibrated_ratio_hard_gate", ratio: 12, softGate: false},
		{name: "calibrated_ratio_soft_gate", ratio: 12, softGate: true},
	}
	previousRatio := registry.PrefillToDecodeRatio()
	defer registry.SetPrefillToDecodeRatio(previousRatio)

	scenarios := make([]routingScenarioContract, 0, len(scenarioSpecs))
	for _, spec := range scenarioSpecs {
		registry.SetPrefillToDecodeRatio(spec.ratio)
		fleet, err := routingsim.BuildFleet(nil, routingsim.FleetConfig{
			Model: model, Providers: providers, WarmFraction: 1,
			DecodeTPS: routingsim.ClusteredDecodeTPS(25, 2),
		})
		if err != nil {
			return nil, fmt.Errorf("build routing fleet for %s: %w", spec.name, err)
		}
		results := routingsim.RunWithGate(fleet, trace, spec.softGate)
		report := routingsim.Summarize(results)
		buckets := make([]routingBucketContract, 0, len(report.Buckets))
		for _, bucket := range report.Buckets {
			buckets = append(buckets, routingBucketContract{
				Label: bucket.Label, Total: bucket.Total, Served: bucket.Served,
				MachineBusy: bucket.MachineBusy, TTFTTooSlow: bucket.TTFTTooSlow,
				OtherRejects: bucket.OtherRejects,
			})
		}
		scenarios = append(scenarios, routingScenarioContract{
			Name: spec.name, PrefillToDecodeRatio: spec.ratio, SoftTTFTGate: spec.softGate,
			Total: report.Total, Served: report.Served, MachineBusy: report.MachineBusy,
			TTFTTooSlow: report.TTFTTooSlow, EstimatedCliff: routingsim.EstimatedCliff(results),
			Buckets: buckets,
		})
	}
	contract, err := json.MarshalIndent(routingContractFile{
		SchemaVersion: 1, Model: model, Providers: providers,
		PromptData: "synthetic token counts only; no prompt or response content",
		Scenarios:  scenarios,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal routing contract: %w", err)
	}
	return map[string][]byte{"tests/contracts/routing/ttft_calibration.json": contract}, nil
}
