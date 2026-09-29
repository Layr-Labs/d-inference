package promptwork

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const promptCountEvidence = "../../../docs/reports/evidence/2026-09-28-calibrated-admission"

func readPromptCountEvidence(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(promptCountEvidence, "prompt-count-qualified-"+name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestReviewedPromptCatalogMatchesQualifiedEvidence(t *testing.T) {
	var review struct {
		Qualified bool     `json:"qualified"`
		Errors    []string `json:"errors"`
		ReportSHA string   `json:"report_sha256"`
		Cells     []struct {
			Qualified bool        `json:"qualified"`
			Errors    []string    `json:"errors"`
			Candidate Calibration `json:"candidate"`
		} `json:"cells"`
	}
	if err := json.Unmarshal(readPromptCountEvidence(t, "review.json"), &review); err != nil {
		t.Fatal(err)
	}
	if !review.Qualified || len(review.Errors) != 0 || len(review.Cells) != 6 || len(reviewedCalibrations) != 6 || !HasCalibrations() {
		t.Fatalf("qualified evidence/catalog unexpectedly empty: evidence=%d catalog=%d", len(review.Cells), len(reviewedCalibrations))
	}
	hash := sha256.New()
	hash.Write(readPromptCountEvidence(t, "receipt.json"))
	hash.Write([]byte{'\n'})
	hash.Write(readPromptCountEvidence(t, "projections.jsonl"))
	if got := hex.EncodeToString(hash.Sum(nil)); got != review.ReportSHA {
		t.Fatalf("numeric receipt/projection digest = %s; review = %s", got, review.ReportSHA)
	}
	for i, cell := range review.Cells {
		if !cell.Qualified || len(cell.Errors) != 0 || cell.Candidate.ReportSHA256 != review.ReportSHA || !reflect.DeepEqual(cell.Candidate, reviewedCalibrations[i]) {
			t.Fatalf("catalog cell %d differs from its qualified candidate", i)
		}
	}
}

func TestReviewedPromptCatalogAppliesToRealTrainingShapes(t *testing.T) {
	var receipt struct {
		Observations []struct {
			ID        string `json:"id"`
			Partition string `json:"partition"`
			Hash      string `json:"workloadSHA256"`
			Actual    int    `json:"actualPromptTokens"`
		} `json:"observations"`
	}
	if err := json.Unmarshal(readPromptCountEvidence(t, "receipt.json"), &receipt); err != nil {
		t.Fatal(err)
	}
	type projection struct {
		Hash     string `json:"workload_sha256"`
		Estimate int    `json:"estimated_tokens"`
		Known    bool   `json:"shape_known"`
		Shape    Shape  `json:"shape"`
	}
	projections := make(map[string]projection)
	scanner := bufio.NewScanner(bytes.NewReader(readPromptCountEvidence(t, "projections.jsonl")))
	for scanner.Scan() {
		var p projection
		if err := json.Unmarshal(scanner.Bytes(), &p); err != nil {
			t.Fatal(err)
		}
		if _, exists := projections[p.Hash]; exists {
			t.Fatal("duplicate projected workload")
		}
		projections[p.Hash] = p
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if len(reviewedCalibrations) != 6 {
		t.Fatal("promotion disabled by runtime validation")
	}
	for _, c := range reviewedCalibrations {
		t.Run(c.ID, func(t *testing.T) {
			parts := strings.Split(c.ID, "-")
			group := parts[len(parts)-2] + "-" + parts[len(parts)-1]
			training, validation, covered := 0, 0, 0
			for _, observed := range receipt.Observations {
				if !strings.Contains(observed.ID, "-"+group+"-") {
					continue
				}
				p, exists := projections[observed.Hash]
				if !exists || !p.Known {
					t.Fatal("observed workload lacks its canonical shape")
				}
				work := c.Estimate(c.ModelID, c.ModelArtifactHash, c.PromptContractID, p.Estimate, c.HasTools, p.Shape)
				if observed.Partition == "validation" {
					validation++
					if work != nil && observed.Actual <= work.UpperBoundTokens {
						covered++
					}
					continue
				}
				if observed.Partition != "calibration" {
					t.Fatal("unknown receipt partition")
				}
				training++
				if work == nil {
					t.Fatalf("real training shape rejected; independent survival = %.17g", binomialSurvival(c.ValidationSamples, c.ValidationCovered, c.TailCoverageLowerBound))
				}
				if work.UpperBoundTokens != int(math.Ceil(float64(p.Estimate)*c.UpperRatio+c.UpperAdditiveTokens)) || work.PromptTokens != int(math.Ceil(float64(p.Estimate)*c.MedianRatio)) {
					t.Fatal("runtime coefficients differ from reviewed fit")
				}
				if training != 1 {
					continue
				}
				if got := Calibrated(c.ModelID, c.ModelArtifactHash, c.PromptContractID, p.Estimate, c.HasTools, p.Shape); !reflect.DeepEqual(work, got) {
					t.Fatal("catalog did not apply qualified training shape")
				}
				outside := p.Shape
				outside.MessageBytes = c.ShapeDomain.MessageBytes.Max + 1
				if Calibrated(c.ModelID, c.ModelArtifactHash, c.PromptContractID, p.Estimate, c.HasTools, outside) != nil ||
					Calibrated(c.ModelID, strings.Repeat("0", 64), c.PromptContractID, p.Estimate, c.HasTools, p.Shape) != nil ||
					Calibrated(c.ModelID, c.ModelArtifactHash, strings.Repeat("0", 64), p.Estimate, c.HasTools, p.Shape) != nil ||
					Calibrated(c.ModelID, c.ModelArtifactHash, c.PromptContractID, p.Estimate, !c.HasTools, p.Shape) != nil ||
					Calibrated(c.ModelID, c.ModelArtifactHash, c.PromptContractID, 8000, c.HasTools, p.Shape) != nil {
					t.Fatal("identity, shape, tools or unmeasured estimate gap borrowed evidence")
				}
			}
			if training != c.TrainingSamples || validation != c.ValidationSamples || covered != c.ValidationCovered {
				t.Fatalf("runtime populations/coverage = %d/%d/%d; reviewed = %d/%d/%d", training, validation, covered, c.TrainingSamples, c.ValidationSamples, c.ValidationCovered)
			}
		})
	}
}

func TestReviewedPromptCatalogFailsClosed(t *testing.T) {
	c, _ := promptCalibrationFixture()
	valid, err := json.Marshal([]Calibration{c})
	if err != nil || len(loadReviewedCalibrations(valid)) != 1 {
		t.Fatal("valid synthetic catalog rejected")
	}
	invalid := c
	invalid.ID = "invalid-confidence"
	invalid.TailCoverageLowerBound = .99
	badConfidence, _ := json.Marshal([]Calibration{c, invalid})
	duplicate, _ := json.Marshal([]Calibration{c, c})
	for _, data := range [][]byte{[]byte("["), append(append([]byte{}, valid...), []byte("[]")...),
		bytes.Replace(valid, []byte(`"id":`), []byte(`"unknown":1,"id":`), 1), badConfidence, duplicate} {
		if len(loadReviewedCalibrations(data)) != 0 {
			t.Fatal("malformed release data partially qualified")
		}
	}
}
