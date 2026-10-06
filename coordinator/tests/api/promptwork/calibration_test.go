package promptwork_test

import (
	"math"
	"strings"
	"testing"

	calibration "github.com/eigeninference/d-inference/coordinator/internal/promptwork/calibration"
)

func promptCalibrationFixture() (calibration.Calibration, calibration.Shape) {
	shape := calibration.Shape{BodyBytes: 1000, MessageCount: 2, MessageBytes: 800, ToolDefinitionCount: 1, ToolDefinitionBytes: 100}
	r := func(n int) calibration.ShapeRange { return calibration.ShapeRange{Min: n, Max: n} }
	return calibration.Calibration{ID: "synthetic-only", ModelID: "model", ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64), ReportSHA256: strings.Repeat("c", 64),
		MinEstimatedTokens: 200, MaxEstimatedTokens: 300, HasTools: true,
		ShapeDomain: &calibration.ShapeDomain{BodyBytes: r(1000), MessageCount: r(2), MessageBytes: r(800), ToolDefinitionCount: r(1), ToolDefinitionBytes: r(100)},
		MedianRatio: 1.125, UpperRatio: 1.3, UpperAdditiveTokens: 10, TrainingSamples: 20, ValidationSamples: 59, ValidationCovered: 59, TailCoverageLowerBound: .95}, shape
}

func TestPromptCalibrationRequiresMeasuredFeatureDomain(t *testing.T) {
	c, shape := promptCalibrationFixture()
	work := c.Estimate("model", c.ModelArtifactHash, c.PromptContractID, 200, true, shape)
	if work == nil || work.PromptTokens != 225 || work.UpperBoundTokens != 270 {
		t.Fatalf("bounded synthetic estimate = %+v", work)
	}
	for _, tc := range []struct {
		name   string
		change func(*calibration.Shape)
	}{
		{"large schema", func(s *calibration.Shape) { s.ToolDefinitionBytes++ }},
		{"more tools", func(s *calibration.Shape) { s.ToolDefinitionCount++ }},
		{"history", func(s *calibration.Shape) { s.MessageCount++ }},
		{"large body", func(s *calibration.Shape) { s.BodyBytes++ }},
		{"system overhead", func(s *calibration.Shape) { s.SystemMessageCount++ }},
		{"tool call history", func(s *calibration.Shape) { s.ToolCallCount++ }},
		{"tool result history", func(s *calibration.Shape) { s.ToolResultCount++ }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			changed := shape
			tc.change(&changed)
			if c.Estimate("model", c.ModelArtifactHash, c.PromptContractID, 200, true, changed) != nil {
				t.Fatal("unmeasured shape borrowed identical estimate/tools flag")
			}
		})
	}
	c.ShapeDomain = nil
	if c.Estimate("model", c.ModelArtifactHash, c.PromptContractID, 200, true, shape) != nil {
		t.Fatal("missing domain became unbounded")
	}
}

func TestPromptCalibrationIndependentCoverageAndMalformedCoefficients(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*calibration.Calibration)
	}{
		{"training nineteen", func(c *calibration.Calibration) { c.TrainingSamples = 19 }},
		{"validation fifty eight", func(c *calibration.Calibration) { c.ValidationSamples = 58; c.ValidationCovered = 58 }},
		{"one miss in fifty nine", func(c *calibration.Calibration) { c.ValidationCovered = 58 }},
		{"huge corpus allocation", func(c *calibration.Calibration) { c.ValidationSamples = math.MaxInt; c.ValidationCovered = math.MaxInt }},
		{"false claimed confidence", func(c *calibration.Calibration) { c.TailCoverageLowerBound = .99 }},
		{"NaN ratio", func(c *calibration.Calibration) { c.UpperRatio = math.NaN() }},
		{"infinite ratio", func(c *calibration.Calibration) { c.UpperRatio = math.Inf(1) }},
		{"negative additive", func(c *calibration.Calibration) { c.UpperAdditiveTokens = -1 }},
		{"upper below center", func(c *calibration.Calibration) { c.UpperRatio = 1 }},
		{"invalid domain", func(c *calibration.Calibration) { c.ShapeDomain.BodyBytes.Min = 1001 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, s := promptCalibrationFixture()
			tc.change(&c)
			if c.Estimate("model", c.ModelArtifactHash, c.PromptContractID, 200, true, s) != nil {
				t.Fatal("invalid or unqualified evidence accepted")
			}
		})
	}
}

func TestPromptCalibrationOverlapsUseLargestUpperBound(t *testing.T) {
	a, shape := promptCalibrationFixture()
	b := a
	b.ID = "larger"
	b.UpperAdditiveTokens = 50
	for _, catalog := range [][]calibration.Calibration{{a, b}, {b, a}} {
		work := calibration.Calibrate(catalog, "model", a.ModelArtifactHash, a.PromptContractID, 200, true, shape)
		if work == nil || work.CalibrationID != b.ID || work.UpperBoundTokens != 310 {
			t.Fatalf("optimistic catalog order: %+v", work)
		}
	}
}
