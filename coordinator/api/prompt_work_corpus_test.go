package api

import (
	"bufio"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

type promptCountProjection struct {
	CorpusID        string           `json:"corpus_id"`
	WorkloadSHA256  string           `json:"workload_sha256"`
	EstimatedTokens int              `json:"estimated_tokens"`
	ShapeKnown      bool             `json:"shape_known"`
	Shape           promptwork.Shape `json:"shape"`
}

// Project the generator's ID and exact original bytes together, before any
// provider counts are observed. Never recover cohort labels from a receipt.
func projectPromptCountCorpusRecord(encoded []byte) (promptCountProjection, error) {
	var input struct {
		ID      string `json:"id"`
		Request []byte `json:"request"`
	}
	if err := json.Unmarshal(encoded, &input); err != nil {
		return promptCountProjection{}, err
	}
	if input.ID == "" || len(input.ID) > 128 || len(input.Request) == 0 || len(input.Request) > promptcontract.DefaultMaxRequestBytes {
		return promptCountProjection{}, fmt.Errorf("missing or invalid canonical corpus ID/request")
	}
	var parsed map[string]any
	if err := json.Unmarshal(input.Request, &parsed); err != nil {
		return promptCountProjection{}, err
	}
	shape, known := promptwork.ShapeFromBody(input.Request)
	digest := sha256.Sum256(input.Request)
	return promptCountProjection{input.ID, hex.EncodeToString(digest[:]), estimatePromptTokens(parsed), known, shape}, nil
}

func TestPromptCountProjectionBindsOriginalCorpusID(t *testing.T) {
	body := []byte(`{ "messages": [{"role":"user","content":"original bytes"}] }`)
	const id = "validation-tools0-band0-17"
	input, err := json.Marshal(map[string]any{"id": id, "request": body})
	if err != nil {
		t.Fatal(err)
	}
	row, err := projectPromptCountCorpusRecord(input)
	digest := sha256.Sum256(body)
	if err != nil || row.CorpusID != id || row.WorkloadSHA256 != hex.EncodeToString(digest[:]) || !row.ShapeKnown {
		t.Fatalf("canonical projection lost its original identity/bytes: %+v, %v", row, err)
	}
	for _, invalid := range [][]byte{body, []byte(`{"id":"validation-tools0-band0-17"}`)} {
		if _, err := projectPromptCountCorpusRecord(invalid); err == nil {
			t.Fatal("unbound corpus input was accepted")
		}
	}
}

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
	scanner.Buffer(make([]byte, 64*1024), base64.StdEncoding.EncodedLen(promptcontract.DefaultMaxRequestBytes)+1024)
	count := 0
	for scanner.Scan() {
		row, err := projectPromptCountCorpusRecord(scanner.Bytes())
		if err != nil {
			t.Fatalf("invalid synthetic request at line %d", count+1)
		}
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
