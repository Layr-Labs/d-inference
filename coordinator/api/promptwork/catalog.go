package promptwork

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"io"
)

// reviewedCatalog is release data copied from qualified, independently held-out
// corpus receipts. These stress-corpus coefficients apply only to the measured
// identity and shape domains; they do not describe production traffic medians.
//
//go:embed catalog/prompt_counts.json
var reviewedCatalog []byte

var reviewedCalibrations = loadReviewedCalibrations(reviewedCatalog)

// Invalid release data disables the fallback rather than certifying a partial
// or unbounded catalog. Exact tokenizer counts remain the preferred path.
func loadReviewedCalibrations(data []byte) []Calibration {
	if len(data) > 1<<20 {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var catalog []Calibration
	if decoder.Decode(&catalog) != nil || len(catalog) > 256 || decoder.Decode(new(any)) != io.EOF {
		return nil
	}
	seen := make(map[string]bool, len(catalog))
	for _, c := range catalog {
		if c.ModelID == "" || c.ShapeDomain == nil || seen[c.ID] {
			return nil
		}
		seen[c.ID] = true
		d := c.ShapeDomain
		shape := Shape{BodyBytes: d.BodyBytes.Min, MessageCount: d.MessageCount.Min, MessageBytes: d.MessageBytes.Min,
			SystemMessageCount: d.SystemMessageCount.Min, DeveloperMessageCount: d.DeveloperMessageCount.Min, AssistantMessageCount: d.AssistantMessageCount.Min,
			ToolDefinitionCount: d.ToolDefinitionCount.Min, ToolDefinitionBytes: d.ToolDefinitionBytes.Min,
			ToolCallCount: d.ToolCallCount.Min, ToolCallBytes: d.ToolCallBytes.Min,
			ToolResultCount: d.ToolResultCount.Min, ToolResultBytes: d.ToolResultBytes.Min}
		for _, estimate := range []int{c.MinEstimatedTokens, c.MaxEstimatedTokens} {
			if c.Estimate(c.ModelID, c.ModelArtifactHash, c.PromptContractID, estimate, c.HasTools, shape) == nil {
				return nil
			}
		}
	}
	return catalog
}
