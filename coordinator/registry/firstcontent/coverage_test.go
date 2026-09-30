package firstcontent

import (
	"encoding/json"
	"math"
	"os"
	"testing"
)

func TestDeadlineCoverageMatchesPythonConfidenceBound(t *testing.T) {
	data, err := os.ReadFile("../../protocol/testdata/deadline_coverage_confidence.json")
	if err != nil {
		t.Fatal(err)
	}
	var shared struct {
		Cases []struct {
			Name     string  `json:"name"`
			Training int     `json:"calibration_sample_count"`
			Total    int     `json:"validation_sample_count"`
			Covered  int     `json:"validation_covered_count"`
			Target   float64 `json:"tail_coverage"`
			Valid    bool    `json:"valid"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &shared); err != nil {
		t.Fatal(err)
	}
	if len(shared.Cases) != 16 {
		t.Fatal("missing shared Python confidence boundaries")
	}
	for _, row := range shared.Cases {
		t.Run(row.Name, func(t *testing.T) {
			calibration, work := fixture()
			cell := &calibration.Cells[0]
			cell.CalibrationSampleCount, cell.ValidationSampleCount = row.Training, row.Total
			cell.ValidationCoveredCount, cell.TailCoverage = row.Covered, row.Target
			if valid := calibration.Valid(32768); valid != row.Valid {
				t.Fatalf("valid=%v, want Python=%v", valid, row.Valid)
			}
			if _, ok := calibration.Predict(work); ok != row.Valid {
				t.Fatalf("prediction eligibility=%v, want %v", ok, row.Valid)
			}
		})
	}
}

func TestDeadlineCoverageRefusesUnboundedOrNonfiniteEditedCounts(t *testing.T) {
	for _, mutate := range []func(*Cell){
		func(c *Cell) { c.CalibrationSampleCount = math.MaxInt },
		func(c *Cell) { c.ValidationSampleCount, c.ValidationCoveredCount = math.MaxInt, math.MaxInt },
		func(c *Cell) { c.ValidationCoveredCount = -1 },
		func(c *Cell) { c.ValidationCoveredCount = 101 },
		func(c *Cell) { c.TailCoverage = math.NaN() },
		func(c *Cell) { c.TailCoverage = math.Inf(1) },
	} {
		calibration, work := fixture()
		mutate(&calibration.Cells[0])
		if calibration.Valid(32768) {
			t.Fatal("invalid evidence accepted")
		}
		if _, ok := calibration.Predict(work); ok {
			t.Fatal("invalid evidence reached prediction")
		}
	}
}
