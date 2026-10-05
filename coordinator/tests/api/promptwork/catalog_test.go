package promptwork_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/promptwork"

	calibration "github.com/eigeninference/d-inference/coordinator/internal/promptwork/calibration"
)

func reviewedCatalogFixture(t *testing.T) ([]byte, []calibration.Calibration) {
	t.Helper()
	data, err := os.ReadFile("../../../api/promptwork/catalog/prompt_counts.json")
	if err != nil {
		t.Fatal(err)
	}
	return data, calibration.Load(data)
}

// Keep the reviewed release coefficients unchanged when raw corpus archives
// are not present in a checkout. Reproduce changed coefficients with the
// opt-in evidence tests before deliberately updating this digest.
func TestReviewedPromptCatalogReleaseData(t *testing.T) {
	reviewedCatalog, reviewedCalibrations := reviewedCatalogFixture(t)
	const expectedSHA256 = "bdb8a03c59b1282c0a2d776226e35bf482f8c3a8d5d3b32ca59f1e26bb1b3fee"
	digest := sha256.Sum256(reviewedCatalog)
	if hex.EncodeToString(digest[:]) != expectedSHA256 {
		t.Fatal("reviewed prompt coefficients changed; verify the raw archive before updating the release digest")
	}
	if len(reviewedCalibrations) != 6 || !production.HasCalibrations() {
		t.Fatal("the six reviewed prompt-count records must remain usable")
	}
}

func TestReviewedPromptCatalogFailsClosed(t *testing.T) {
	c, _ := promptCalibrationFixture()
	valid, err := json.Marshal([]calibration.Calibration{c})
	if err != nil || len(calibration.Load(valid)) != 1 {
		t.Fatal("valid synthetic catalog rejected")
	}
	invalid := c
	invalid.ID = "invalid-confidence"
	invalid.TailCoverageLowerBound = .99
	badConfidence, _ := json.Marshal([]calibration.Calibration{c, invalid})
	duplicate, _ := json.Marshal([]calibration.Calibration{c, c})
	for _, data := range [][]byte{[]byte("["), append(append([]byte{}, valid...), []byte("[]")...),
		bytes.Replace(valid, []byte(`"id":`), []byte(`"unknown":1,"id":`), 1), badConfidence, duplicate} {
		if len(calibration.Load(data)) != 0 {
			t.Fatal("malformed release data partially qualified")
		}
	}
}
