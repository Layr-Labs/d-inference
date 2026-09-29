package api

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// TestPromptWorkQualificationCorpus projects temporary synthetic requests into
// numeric evidence using the production estimator. It never exports messages,
// schemas, tool arguments, or request body bytes.
func TestPromptWorkQualificationCorpus(t *testing.T) {
	input := os.Getenv("DARKBLOOM_PROMPT_COUNT_CORPUS")
	if input == "" {
		t.Skip("opt-in synthetic qualification corpus")
	}
	output := os.Getenv("DARKBLOOM_PROMPT_COUNT_OUTPUT")
	if output == "" || output == input {
		t.Fatal("a separate numeric output path is required")
	}
	in, err := os.Open(input)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	encoder := json.NewEncoder(out)
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64*1024), promptcontract.DefaultMaxRequestBytes+1)
	count := 0
	for scanner.Scan() {
		body := scanner.Bytes()
		var parsed map[string]any
		if err := json.Unmarshal(body, &parsed); err != nil {
			t.Fatalf("invalid synthetic request at line %d", count+1)
		}
		shape, known := promptwork.ShapeFromBody(body)
		digest := sha256.Sum256(body)
		row := struct {
			WorkloadSHA256  string           `json:"workload_sha256"`
			EstimatedTokens int              `json:"estimated_tokens"`
			ShapeKnown      bool             `json:"shape_known"`
			Shape           promptwork.Shape `json:"shape"`
		}{hex.EncodeToString(digest[:]), estimatePromptTokens(parsed), known, shape}
		if err := encoder.Encode(row); err != nil {
			t.Fatal(err)
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("synthetic qualification corpus was empty")
	}
	if err := out.Sync(); err != nil {
		t.Fatal(err)
	}
}
