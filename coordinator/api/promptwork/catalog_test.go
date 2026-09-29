package promptwork

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
)

// Keep the reviewed release coefficients unchanged when raw corpus archives
// are not present in a checkout. Reproduce changed coefficients with the
// opt-in evidence tests before deliberately updating this digest.
func TestReviewedPromptCatalogReleaseData(t *testing.T) {
	const expectedSHA256 = "bdb8a03c59b1282c0a2d776226e35bf482f8c3a8d5d3b32ca59f1e26bb1b3fee"
	digest := sha256.Sum256(reviewedCatalog)
	if hex.EncodeToString(digest[:]) != expectedSHA256 {
		t.Fatal("reviewed prompt coefficients changed; verify the raw archive before updating the release digest")
	}
	if len(reviewedCalibrations) != 6 || !HasCalibrations() {
		t.Fatal("the six reviewed prompt-count records must remain usable")
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
