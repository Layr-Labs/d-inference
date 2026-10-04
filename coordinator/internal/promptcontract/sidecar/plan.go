package sidecar

import (
	"encoding/hex"
	"encoding/json"
	"strings"

	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

type Endpoint string

const (
	EndpointChatCompletions Endpoint = "chat_completions"
	EndpointCompletions     Endpoint = "completions"
	EndpointResponses       Endpoint = "responses"
	EndpointMessages        Endpoint = "messages"
)

type PlanInput struct {
	PromptContractID string
	ScopeID          string
	Endpoint         Endpoint
	Body             json.RawMessage
}

type Boundary struct {
	TokenCount uint32 `json:"token_count"`
	ChainHash  string `json:"chain_hash"`
}

type Plan struct {
	Participating         bool       `json:"-"`
	PromptContractID      string     `json:"prompt_contract_id"`
	PromptTokenCount      uint32     `json:"prompt_token_count"`
	BlockBoundaries       []Boundary `json:"block_boundaries"`
	LastCompleteBlockHash *string    `json:"last_complete_block_hash,omitempty"`
}

func ValidatePlan(input PlanInput, plan Plan, maxTokens int) error {
	if plan.PromptContractID != input.PromptContractID ||
		uint64(plan.PromptTokenCount) > uint64(maxTokens) {
		return ErrInvalidPlan
	}
	expectedBoundaries := 0
	if plan.PromptTokenCount > 0 {
		expectedBoundaries = int((plan.PromptTokenCount - 1) / identity.BlockSize)
	}
	if len(plan.BlockBoundaries) != expectedBoundaries {
		return ErrInvalidPlan
	}
	for index, boundary := range plan.BlockBoundaries {
		if boundary.TokenCount != uint32(index+1)*identity.BlockSize || !ValidHash(boundary.ChainHash) {
			return ErrInvalidPlan
		}
	}
	if expectedBoundaries == 0 {
		if plan.LastCompleteBlockHash != nil {
			return ErrInvalidPlan
		}
	} else if plan.LastCompleteBlockHash == nil ||
		*plan.LastCompleteBlockHash != plan.BlockBoundaries[expectedBoundaries-1].ChainHash {
		return ErrInvalidPlan
	}
	return nil
}

func ValidEndpoint(endpoint Endpoint) bool {
	switch endpoint {
	case EndpointChatCompletions, EndpointCompletions, EndpointResponses, EndpointMessages:
		return true
	default:
		return false
	}
}

func ValidHash(value string) bool {
	if len(value) != sha256HexLength {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && value == strings.ToLower(value)
}

const sha256HexLength = 64
