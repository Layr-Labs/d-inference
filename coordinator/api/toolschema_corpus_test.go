package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

const toolSchemaNormalizationFixtureVersion uint32 = 1

type toolSchemaNormalizationCorpus struct {
	SchemaVersion *uint32                       `json:"schema_version"`
	Cases         []toolSchemaNormalizationCase `json:"cases"`
}

type toolSchemaNormalizationCase struct {
	Name       string          `json:"name"`
	Mode       string          `json:"mode"`
	Acceptance string          `json:"acceptance"`
	Input      json.RawMessage `json:"input"`
	Normalized json.RawMessage `json:"normalized"`
}

func TestNormalizeToolSchemas_SharedNormalizationCorpus(t *testing.T) {
	corpus, err := loadToolSchemaNormalizationCorpus()
	if err != nil {
		t.Fatal(err)
	}

	names := make(map[string]struct{}, len(corpus.Cases))
	for _, tc := range corpus.Cases {
		tc := tc
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Name == "" {
				t.Fatal("fixture case name is empty")
			}
			if _, duplicate := names[tc.Name]; duplicate {
				t.Fatalf("duplicate fixture case name %q", tc.Name)
			}
			names[tc.Name] = struct{}{}
			if tc.Mode != "normalize" {
				t.Fatalf("unsupported fixture mode %q", tc.Mode)
			}

			input := decodeToolSchemaFixtureJSON(t, tc.Input)
			expected := decodeToolSchemaFixtureJSON(t, tc.Normalized)
			switch tc.Acceptance {
			case "rewritten":
				if reflect.DeepEqual(input, expected) {
					t.Fatal("rewritten case has identical input and normalized structures")
				}
			case "preserved":
				if !reflect.DeepEqual(input, expected) {
					t.Fatal("preserved case changes the normalized structure")
				}
			default:
				t.Fatalf("unsupported fixture acceptance %q", tc.Acceptance)
			}

			normalized := NormalizeToolSchemas(tc.Input)
			actual := decodeToolSchemaFixtureJSON(t, normalized)
			if !reflect.DeepEqual(actual, expected) {
				t.Errorf("normalized structure mismatch\n got: %s\nwant: %s", normalized, tc.Normalized)
			}

			// Every shared vector also pins idempotence. Decoding with UseNumber
			// makes the equality sensitive to exact JSON number spellings and
			// prevents 2^53+1 from silently becoming 2^53.
			twice := NormalizeToolSchemas(normalized)
			idempotent := decodeToolSchemaFixtureJSON(t, twice)
			if !reflect.DeepEqual(idempotent, expected) {
				t.Errorf("second normalization changed the structure\n got: %s\nwant: %s", twice, tc.Normalized)
			}
		})
	}
}

func TestToolSchemaNormalizationFixtureSchemaVersionFailsClosed(t *testing.T) {
	for name, encoded := range map[string][]byte{
		"missing": []byte(`{"cases":[]}`),
		"unknown": []byte(`{"schema_version":2,"cases":[]}`),
	} {
		t.Run(name, func(t *testing.T) {
			var corpus toolSchemaNormalizationCorpus
			if err := decodeToolSchemaNormalizationCorpus(encoded, &corpus); err == nil {
				t.Fatal("fixture with missing or unsupported schema version was accepted")
			}
		})
	}
}

func loadToolSchemaNormalizationCorpus() (toolSchemaNormalizationCorpus, error) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		return toolSchemaNormalizationCorpus{}, errors.New("resolve tool-schema corpus test path")
	}
	path := filepath.Join(
		filepath.Dir(currentFile), "..", "..",
		"fixtures", "tool-schema", "v1", "normalization.json",
	)
	encoded, err := os.ReadFile(path)
	if err != nil {
		return toolSchemaNormalizationCorpus{}, err
	}
	var corpus toolSchemaNormalizationCorpus
	if err := decodeToolSchemaNormalizationCorpus(encoded, &corpus); err != nil {
		return toolSchemaNormalizationCorpus{}, err
	}
	return corpus, nil
}

func decodeToolSchemaNormalizationCorpus(
	encoded []byte,
	corpus *toolSchemaNormalizationCorpus,
) error {
	var metadata struct {
		SchemaVersion *uint32 `json:"schema_version"`
	}
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		return err
	}
	if metadata.SchemaVersion == nil {
		return errors.New("fixture schema version is missing")
	}
	if *metadata.SchemaVersion != toolSchemaNormalizationFixtureVersion {
		return fmt.Errorf("unsupported fixture schema version %d", *metadata.SchemaVersion)
	}
	return json.Unmarshal(encoded, corpus)
}

func decodeToolSchemaFixtureJSON(t *testing.T, encoded []byte) any {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		t.Fatalf("decode fixture JSON: %v", err)
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		t.Fatalf("fixture JSON has trailing content: %v", err)
	}
	return value
}

// The shared corpus owns the normalization golden. This consumer test remains
// local because it also verifies the coordinator's constrained-mode validator
// accepts the canonical allow-all marker and rejects forged metadata.
func TestConstrainedValidationAcceptsNormalizedEmptySchemaMarker(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"lookup",
			"parameters":{"type":"object","properties":{"x":{}}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("pre-normalization validation: %v", err)
	}
	normalized := NormalizeToolSchemas(body)
	if _, err := validateToolConstraintRequest(normalized); err != nil {
		t.Fatalf("post-normalization validation: %v\n%s", err, normalized)
	}

	forged := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"lookup",
			"parameters":{"type":"object","properties":{"x":{
				"type":"string",
				"x-darkbloom-original-boolean-schema":false
			}}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(forged); err == nil {
		t.Fatal("non-canonical marker shape accepted in constrained mode")
	}
}
