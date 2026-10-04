// Package conformance contains test-only HTTP conformance scenarios and their
// observers. The thin inference contract adapter binds the composed server and
// its retained dependencies; production code must not import this package.
package conformance

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Server exposes only the existing operations exercised by this suite.
type Server interface {
	Handler() http.Handler
	Close()
	SyncModelCatalog()
	Inflight() int64
	SetDraining(bool)
}

// Backend binds the real server and test-only ownership observations without
// adding production getters, changing authentication, or copying a server.
// Outstanding reports an account's unreleased service hold in micro-USD.
type Backend struct {
	Server
	Registry    *registry.Registry
	Outstanding func(account string) int64
}

// Suite carries the one per-invocation factory the importing test package
// supplies; it has no mutable global server hook. NewServer composes the real
// runtime over the fixture's store and returns what it retained. Its holds
// argument enables service-account reservation holds, and slaAccount is the
// only account whose requests get a first-content budget. Provider keys, chunk
// encryption and catalog addresses come from tests/internal/testkit directly.
type Suite struct {
	NewServer func(t *testing.T, st *memory.MemoryStore, holds bool, slaAccount string) Backend
}

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const huggingFaceIDMetadataKey = "hugging_face_id"

// Assert the wire contract independently of the handler's private constants.
const errorReasonDeadlineUnreachable = "deadline_unreachable"
const errorReasonCancelled = "cancelled"

// Shared fixture contracts used by the separate composed cache tests.
const InitialBalanceMicroUSD = orInitial
const RequestCostMicroUSD = orCost

func LoopbackClient(t *testing.T, origin string) *http.Client     { return orLoopbackClient(t, origin) }
func Eventually(t *testing.T, predicate func() bool, what string) { orEventually(t, predicate, what) }

// Wire DTO intentionally independent of the handler's private request type.
type registerModelRequest struct {
	HuggingFaceArtifact *store.HuggingFaceArtifact `json:"hugging_face_artifact,omitempty"`
	ModelID             string                     `json:"model_id"`
	Version             string                     `json:"version"`
	DisplayName         string                     `json:"display_name"`
	Family              string                     `json:"family"`
	Architecture        string                     `json:"architecture"`
	Quantization        string                     `json:"quantization"`
	MaxContextLength    int                        `json:"max_context_length"`
	MaxOutputLength     int                        `json:"max_output_length"`
	MinRAMGB            int                        `json:"min_ram_gb"`
	Capabilities        []string                   `json:"capabilities"`
	Metadata            map[string]any             `json:"metadata"`
	Promote             bool                       `json:"promote"`
	InputPrice          int64                      `json:"input_price"`
	OutputPrice         int64                      `json:"output_price"`
}
