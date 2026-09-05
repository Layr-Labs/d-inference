package promptcontract

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLowerResponsesInstructions(t *testing.T) {
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "prompt-contract", "v1", "responses_instructions.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name     string          `json:"name"`
		Request  json.RawMessage `json:"request"`
		Expected json.RawMessage `json:"expected"`
		Invalid  bool            `json:"invalid"`
	}
	if err := json.Unmarshal(encoded, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			got, err := LowerProviderBody(EndpointResponses, tc.Request)
			if tc.Invalid {
				if !errors.Is(err, ErrEndpointBodyInvalid) {
					t.Fatalf("error = %v, want ErrEndpointBodyInvalid", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if want := canonicalJSON(t, tc.Expected); !bytes.Equal(got, want) {
				t.Fatalf("provider body = %s, want %s", got, want)
			}
		})
	}
}
