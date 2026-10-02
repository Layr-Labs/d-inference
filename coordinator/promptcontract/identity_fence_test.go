package promptcontract

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type identityFenceVector struct {
	Artifacts  []Artifact `json:"artifacts"`
	CurrentID  string     `json:"expected_prompt_contract_id"`
	LegacyID   string     `json:"legacy_v6_prompt_contract_id"`
	LegacyV7ID string     `json:"legacy_v7_prompt_contract_id"`
}

func identityFenceFixture(t *testing.T) identityFenceVector {
	t.Helper()
	var corpus struct {
		Vectors []identityFenceVector `json:"vectors"`
	}
	data, err := os.ReadFile("../../fixtures/prompt-contract/v1/contract_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatal(err)
	}
	if len(corpus.Vectors) != 1 {
		t.Fatal("expected one immutable identity vector")
	}
	return corpus.Vectors[0]
}

// Independent Node SHA-256 pins over these exact four real payloads, using
// length-prefixed UTF-8 and bytewise (not locale) artifact ordering. The oracle
// also reproduced both preserved shared v6/v7 vectors before these pins were set.
const identityFenceTinyV6 = "35f35167c8444a2155269a8873c23e69980b334590762b31fb9bfe97250fa109"
const identityFenceTinyV7 = "1916ae8b83dd77d3c6da1e0860672d79a9c146e2e661ae8e12b3182fb0b57132"
const identityFenceTinyV8 = "6de1b2c93027ed37e6cfbc4112250fbadca0bd90b8d027dc200a710a462b07c7"

func identityFenceTinyPayloads(t *testing.T) ([]Artifact, map[string][]byte) {
	t.Helper()
	rows := []struct{ name, role, body, digest string }{
		{"config.json", "config", `{"model_type":"fixture"}`, "d2445a28eada2ae5e33f04c7346241a88b84042ff69c25f248c7d9bd776f841c"},
		{"tokenizer.json", "tokenizer", `{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"hello":1},"unk_token":"[UNK]"}}`, "591b0d73b5e85a973a76646a8a80117651178da79c01d0422dbaa1c62fa19a9d"},
		{"tokenizer_config.json", "tokenizer", `{"chat_template":"{{ messages[0].content }}"}`, "c54aee6c53a0c37cfb1336db462716220c80146dfa67bc4cdce63fbf99e687e0"},
		{"chat_template.jinja", "template", `{{ messages[0].content }}`, "21b1d9c74a217211f93d54eca585c322017b9008d86619712ec946b10cf156f1"},
	}
	var artifacts []Artifact
	payloads := make(map[string][]byte)
	for _, row := range rows {
		payload := []byte(row.body)
		digest := sha256.Sum256(payload)
		if hex.EncodeToString(digest[:]) != row.digest {
			t.Fatalf("independent tiny payload pin changed: %s", row.name)
		}
		artifacts = append(artifacts, Artifact{Path: row.name, Role: row.role,
			SizeBytes: int64(len(payload)), SHA256: row.digest})
		payloads[row.name] = payload
	}
	return artifacts, payloads
}

func TestNormalizationV8RefusesPublishedV6V7AndMixedMetadataWithoutRewriting(t *testing.T) {
	artifacts, payloads := identityFenceTinyPayloads(t)
	id, err := ContractID(artifacts, CurrentVersions())
	if err != nil || id != identityFenceTinyV8 {
		t.Fatalf("complete tiny current identity differs from independent pin: %s, %v", id, err)
	}
	legacy := CurrentVersions()
	legacy.Normalization = "darkbloom-request-normalization-v6"
	legacy.Renderer = "swift-jinja-request-date-compatible-v3"
	legacyV7 := legacy
	legacyV7.Normalization = "darkbloom-request-normalization-v7"
	if _, err := ContractID(artifacts, legacy); !errors.Is(err, ErrInvalidVersions) {
		t.Fatalf("direct old-version discriminator failed: %v", err)
	}
	for _, tc := range []struct {
		name     string
		id       string
		versions Versions
	}{
		// If old-version admission is removed, this coherent v6 directory has
		// the correct v6 ID and every valid payload: verification would succeed.
		{"valid-old-v6-identity", identityFenceTinyV6, legacy},
		{"v8-directory-v6-semantics", identityFenceTinyV8, legacy},
		{"v6-directory-relabeled-v8", identityFenceTinyV6, CurrentVersions()},
		{"valid-old-v7-identity", identityFenceTinyV7, legacyV7},
		{"v8-directory-v7-semantics", identityFenceTinyV8, legacyV7},
		{"v7-directory-relabeled-v8", identityFenceTinyV7, CurrentVersions()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := realTempDir(t)
			directory := filepath.Join(root, identityFenceTinyV8)
			if err := os.Mkdir(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			for name, payload := range payloads {
				if err := os.WriteFile(filepath.Join(directory, name), payload, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			metadata := Metadata{SchemaVersion: 1, PromptContractID: identityFenceTinyV8,
				ModelID: "fixture", ModelType: "fixture", ModelAggregateSHA256: strings.Repeat("0", 64),
				Artifacts: artifacts, Versions: CurrentVersions()}
			writeMetadata := func() []byte {
				t.Helper()
				data, err := json.Marshal(metadata)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(directory, MetadataFile), data, 0o600); err != nil {
					t.Fatal(err)
				}
				return data
			}
			writeMetadata()
			handle, err := os.OpenRoot(root)
			if err != nil {
				t.Fatal(err)
			}
			defer handle.Close()
			if ok, err := verifyPublished(handle, identityFenceTinyV8); !ok || err != nil {
				t.Fatalf("complete current positive failed before negative mutation: %v", err)
			}
			// This is an isolated test-created directory, not a published cache.
			// Mutate only version/identity dimensions; payloads are never rewritten.
			if tc.id != identityFenceTinyV8 {
				next := filepath.Join(root, tc.id)
				if err := os.Rename(directory, next); err != nil {
					t.Fatal(err)
				}
				directory = next
			}
			metadata.PromptContractID, metadata.Versions = tc.id, tc.versions
			before := writeMetadata()
			for _, artifact := range artifacts {
				if err := verifyPublishedArtifact(handle, tc.id, artifact); err != nil {
					t.Fatalf("negative is not payload-complete: %s: %v", artifact.Path, err)
				}
			}
			if ok, err := verifyPublished(handle, tc.id); ok || !errors.Is(err, ErrArtifactIntegrity) {
				t.Fatalf("complete old/mixed contract accepted: ok=%v error=%v", ok, err)
			}
			after, err := os.ReadFile(filepath.Join(directory, MetadataFile))
			if err != nil || !bytes.Equal(before, after) {
				t.Fatal("verification changed the legacy artifact metadata")
			}
			for name, expected := range payloads {
				actual, err := os.ReadFile(filepath.Join(directory, name))
				if err != nil || !bytes.Equal(actual, expected) {
					t.Fatalf("verification changed payload %s", name)
				}
			}
		})
	}
}

func TestNormalizationV8RefusesStalePlansAndRekeysUnchangedTokenBlocks(t *testing.T) {
	fixture := identityFenceFixture(t)
	tokens := make([]uint32, 256)
	for index := range tokens {
		tokens[index] = uint32(index)
	}
	plan := func(id string) Plan {
		digest, err := BlockHash([]byte(id), []byte("same-scope"), [32]byte{}, 0, tokens)
		if err != nil {
			t.Fatal(err)
		}
		hash := hex.EncodeToString(digest[:])
		return Plan{PromptContractID: id, PromptTokenCount: 257,
			BlockBoundaries: []Boundary{{TokenCount: 256, ChainHash: hash}}, LastCompleteBlockHash: &hash}
	}
	current := plan(fixture.CurrentID)
	client := &Client{config: ClientConfig{MaxTokens: 1024}}
	for _, legacyID := range []string{fixture.LegacyID, fixture.LegacyV7ID} {
		old := plan(legacyID)
		if current.BlockBoundaries[0].ChainHash == old.BlockBoundaries[0].ChainHash {
			t.Fatal("same-token old and new contracts shared a cache block")
		}
		for _, pair := range []struct{ request, response Plan }{{current, old}, {old, current}} {
			if err := client.validatePlan(PlanInput{PromptContractID: pair.request.PromptContractID}, pair.response); !errors.Is(err, ErrInvalidPlan) {
				t.Fatalf("stale cross-version plan accepted: %v", err)
			}
		}
	}
	if err := client.validatePlan(PlanInput{PromptContractID: current.PromptContractID}, current); err != nil {
		t.Fatalf("same-contract positive plan refused: %v", err)
	}
}
