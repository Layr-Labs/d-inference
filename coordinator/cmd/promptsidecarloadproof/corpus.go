package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

const (
	productionCorpusSchema   = 1
	productionModelCount     = 4
	maxProductionCorpusBytes = 16 << 20
)

type productionCorpus struct {
	SchemaVersion uint32            `json:"schema_version"`
	Models        []productionModel `json:"models"`
}

type productionModel struct {
	ModelID              string           `json:"model_id"`
	ModelType            *string          `json:"model_type"`
	PromptContractID     string           `json:"prompt_contract_id"`
	CacheRoutingEligible bool             `json:"cache_routing_eligible"`
	IneligibilityReason  string           `json:"ineligibility_reason"`
	Cases                []productionCase `json:"cases"`
}

type productionCase struct {
	ID            string                  `json:"id"`
	Endpoint      promptcontract.Endpoint `json:"endpoint"`
	ScopeID       string                  `json:"scope_id"`
	RequestBody   json.RawMessage         `json:"request_body"`
	ProviderBody  json.RawMessage         `json:"provider_body"`
	TemplateInput json.RawMessage         `json:"template_input"`
	Plan          promptcontract.Plan     `json:"plan"`
	TokenIDs      []uint32                `json:"token_ids"`
}

type planVector struct {
	Name             string
	ModelID          string
	PromptContractID string
	ScopeID          string
	ProviderBody     json.RawMessage
	Expected         promptcontract.Plan
}

type productionInventory struct {
	Models            int
	EligibleModels    int
	ColdOnlyContracts int
	Contracts         []string
	Vectors           []planVector
}

func readProductionInventory(path string) (productionInventory, error) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 ||
		info.Size() > maxProductionCorpusBytes {
		return productionInventory{}, errors.New("production vectors are missing, unsafe, or exceed their bound")
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		return productionInventory{}, fmt.Errorf("read production vectors: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var corpus productionCorpus
	if err := decoder.Decode(&corpus); err != nil {
		return productionInventory{}, fmt.Errorf("decode production vectors: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return productionInventory{}, errors.New("production vectors contain trailing JSON")
	}
	return validateProductionCorpus(corpus)
}

func validateProductionCorpus(corpus productionCorpus) (productionInventory, error) {
	if corpus.SchemaVersion != productionCorpusSchema {
		return productionInventory{}, fmt.Errorf("unsupported production-vector schema %d", corpus.SchemaVersion)
	}
	if len(corpus.Models) != productionModelCount {
		return productionInventory{}, fmt.Errorf(
			"production-vector model inventory = %d, want %d", len(corpus.Models), productionModelCount)
	}

	modelIDs := make(map[string]struct{}, len(corpus.Models))
	contractIDs := make(map[string]struct{}, len(corpus.Models))
	eligibleContractIDs := make(map[string]struct{}, len(corpus.Models))
	caseNames := make(map[string]struct{})
	endpointCoverage := make(map[promptcontract.Endpoint]struct{})
	eligibleModels := 0
	vectors := make([]planVector, 0)
	for _, model := range corpus.Models {
		if model.ModelID == "" {
			return productionInventory{}, errors.New("production-vector model ID is empty")
		}
		if _, duplicate := modelIDs[model.ModelID]; duplicate {
			return productionInventory{}, fmt.Errorf("duplicate production model %q", model.ModelID)
		}
		modelIDs[model.ModelID] = struct{}{}
		if !validContractID(model.PromptContractID) {
			return productionInventory{}, fmt.Errorf("invalid prompt contract for model %q", model.ModelID)
		}
		if model.ModelType != nil && *model.ModelType == "" {
			return productionInventory{}, fmt.Errorf("empty model type for model %q", model.ModelID)
		}
		contractIDs[model.PromptContractID] = struct{}{}

		if !model.CacheRoutingEligible {
			if model.IneligibilityReason != "dynamic_time" || len(model.Cases) != 0 {
				return productionInventory{}, fmt.Errorf("invalid ineligible model %q", model.ModelID)
			}
			continue
		}
		eligibleModels++
		eligibleContractIDs[model.PromptContractID] = struct{}{}
		if model.IneligibilityReason != "" || len(model.Cases) == 0 {
			return productionInventory{}, fmt.Errorf("eligible model %q has no supported cases", model.ModelID)
		}
		for _, fixture := range model.Cases {
			name := model.ModelID + "/" + fixture.ID
			if fixture.ID == "" {
				return productionInventory{}, fmt.Errorf("model %q has an empty case ID", model.ModelID)
			}
			if _, duplicate := caseNames[name]; duplicate {
				return productionInventory{}, fmt.Errorf("duplicate production vector %q", name)
			}
			caseNames[name] = struct{}{}
			if fixture.ScopeID == "" || !validProductionEndpoint(fixture.Endpoint) ||
				!json.Valid(fixture.RequestBody) || !json.Valid(fixture.ProviderBody) ||
				!json.Valid(fixture.TemplateInput) {
				return productionInventory{}, fmt.Errorf("invalid production vector %q", name)
			}
			if fixture.Plan.PromptContractID != model.PromptContractID ||
				fixture.Plan.PromptTokenCount != uint32(len(fixture.TokenIDs)) {
				return productionInventory{}, fmt.Errorf("plan identity/count mismatch for %q", name)
			}
			endpointCoverage[fixture.Endpoint] = struct{}{}
			vectors = append(vectors, planVector{
				Name:             name,
				ModelID:          model.ModelID,
				PromptContractID: model.PromptContractID,
				ScopeID:          fixture.ScopeID,
				ProviderBody:     append(json.RawMessage(nil), fixture.ProviderBody...),
				Expected:         fixture.Plan,
			})
		}
	}
	if eligibleModels == 0 || len(vectors) == 0 {
		return productionInventory{}, errors.New("production-vector inventory has no routable cases")
	}
	if len(endpointCoverage) != 4 {
		return productionInventory{}, fmt.Errorf(
			"production-vector endpoint coverage = %d, want all four supported endpoints",
			len(endpointCoverage))
	}
	contracts := make([]string, 0, len(contractIDs))
	for contractID := range contractIDs {
		contracts = append(contracts, contractID)
	}
	sort.Strings(contracts)
	return productionInventory{
		Models:            len(corpus.Models),
		EligibleModels:    eligibleModels,
		ColdOnlyContracts: len(contractIDs) - len(eligibleContractIDs),
		Contracts:         contracts,
		Vectors:           vectors,
	}, nil
}

func validProductionEndpoint(endpoint promptcontract.Endpoint) bool {
	switch endpoint {
	case promptcontract.EndpointChatCompletions,
		promptcontract.EndpointCompletions,
		promptcontract.EndpointResponses,
		promptcontract.EndpointMessages:
		return true
	default:
		return false
	}
}

func validContractID(value string) bool {
	if len(value) != 64 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == fmt.Sprintf("%x", decoded)
}
