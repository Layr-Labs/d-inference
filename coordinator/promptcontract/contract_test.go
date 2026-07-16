package promptcontract

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestContractIDIsOrderIndependentAndSemanticallyBound(t *testing.T) {
	if _, err := ContractID(nil, CurrentVersions()); !errors.Is(err, ErrInvalidArtifact) {
		t.Fatalf("empty contract error = %v, want invalid artifact", err)
	}
	artifacts := []Artifact{
		{Path: "tokenizer.json", Role: "tokenizer", SizeBytes: 1, SHA256: hex.EncodeToString(bytesOf(1))},
		{Path: "config.json", Role: "config", SizeBytes: 1, SHA256: hex.EncodeToString(bytesOf(2))},
	}
	first, err := ContractID(artifacts, CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	slices.Reverse(artifacts)
	second, err := ContractID(artifacts, CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("contract ID changed with manifest order: %s != %s", first, second)
	}
	artifacts[0].SHA256 = hex.EncodeToString(bytesOf(3))
	changed, err := ContractID(artifacts, CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	if changed == first {
		t.Fatal("contract ID did not bind artifact digest")
	}
}

func TestSharedBlockHashVectors(t *testing.T) {
	type vector struct {
		ContractID   string `json:"contract_id"`
		ScopeID      string `json:"scope_id"`
		BlockIndex   uint32 `json:"block_index"`
		ParentHash   string `json:"parent_hash"`
		TokenStart   uint32 `json:"token_start"`
		TokenCount   uint32 `json:"token_count"`
		ExpectedHash string `json:"expected_hash"`
	}
	var corpus struct {
		BlockHashVersion string   `json:"block_hash_version"`
		Vectors          []vector `json:"vectors"`
	}
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "prompt-contract", "v1", "block_hash_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if corpus.BlockHashVersion != BlockHashVersion {
		t.Fatalf("fixture version %q != %q", corpus.BlockHashVersion, BlockHashVersion)
	}
	for _, fixture := range corpus.Vectors {
		parentBytes, err := hex.DecodeString(fixture.ParentHash)
		if err != nil {
			t.Fatal(err)
		}
		var parent [32]byte
		copy(parent[:], parentBytes)
		tokens := make([]uint32, fixture.TokenCount)
		for index := range tokens {
			tokens[index] = fixture.TokenStart + uint32(index)
		}
		actual, err := BlockHash(
			[]byte(fixture.ContractID),
			[]byte(fixture.ScopeID),
			parent,
			fixture.BlockIndex,
			tokens,
		)
		if err != nil {
			t.Fatal(err)
		}
		if hex.EncodeToString(actual[:]) != fixture.ExpectedHash {
			t.Fatalf("shared vector mismatch: %x != %s", actual, fixture.ExpectedHash)
		}
	}
}

func TestSharedContractVectors(t *testing.T) {
	var corpus struct {
		Vectors []struct {
			Artifacts                []Artifact `json:"artifacts"`
			ExpectedPromptContractID string     `json:"expected_prompt_contract_id"`
		} `json:"vectors"`
	}
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "prompt-contract", "v1", "contract_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range corpus.Vectors {
		actual, err := ContractID(fixture.Artifacts, CurrentVersions())
		if err != nil {
			t.Fatal(err)
		}
		if actual != fixture.ExpectedPromptContractID {
			t.Fatalf("shared contract vector mismatch: %s != %s", actual, fixture.ExpectedPromptContractID)
		}
	}
}

func TestSharedRequestCorpusCoverage(t *testing.T) {
	var corpus struct {
		SchemaVersion uint32 `json:"schema_version"`
		Cases         []struct {
			ID       string          `json:"id"`
			Endpoint Endpoint        `json:"endpoint"`
			ScopeID  string          `json:"scope_id"`
			Body     json.RawMessage `json:"body"`
		} `json:"cases"`
	}
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "prompt-contract", "v1", "corpus.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if corpus.SchemaVersion != 1 {
		t.Fatalf("fixture schema = %d, want 1", corpus.SchemaVersion)
	}
	seen := make(map[string]bool, len(corpus.Cases))
	for _, fixture := range corpus.Cases {
		if fixture.ID == "" || fixture.ScopeID == "" || !validEndpoint(fixture.Endpoint) || !json.Valid(fixture.Body) {
			t.Fatalf("invalid shared request fixture %q", fixture.ID)
		}
		if seen[fixture.ID] {
			t.Fatalf("duplicate shared request fixture %q", fixture.ID)
		}
		seen[fixture.ID] = true
	}
	for _, required := range []string{
		"tools", "nulls", "harmony", "gemma", "reasoning_effort", "unicode",
		"endpoint_chat_completions", "endpoint_completions", "endpoint_responses",
		"endpoint_messages", "exact_block_multiple", "long_prompt",
	} {
		if !seen[required] {
			t.Fatalf("shared request fixture %q is missing", required)
		}
	}
}

func TestLastCompleteBoundaryReservesFinalToken(t *testing.T) {
	cases := []struct {
		tokens   int
		boundary int
		ok       bool
	}{
		{0, 0, false},
		{255, 0, false},
		{256, 0, false},
		{257, 256, true},
		{511, 256, true},
		{512, 256, true},
		{513, 512, true},
	}
	for _, test := range cases {
		boundary, ok := LastCompleteBoundary(test.tokens, 256)
		if boundary != test.boundary || ok != test.ok {
			t.Fatalf("tokens=%d: got (%d,%t), want (%d,%t)", test.tokens, boundary, ok, test.boundary, test.ok)
		}
	}
}

func bytesOf(value byte) []byte {
	return slices.Repeat([]byte{value}, 32)
}
