// Package conformance contains test-only HTTP conformance scenarios and their
// observers. The parent API package's thin test adapter binds private seams;
// production code must not import this package.
package conformance

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
type Backend struct {
	Server
	Registry    *registry.Registry
	Outstanding func(string) int64
}

// Suite carries per-invocation factories; it has no mutable global server hook.
type Suite struct {
	NewServer           func(*testing.T, *store.MemoryStore, bool, string) Backend
	ModelR2Prefix       func(string, string) string
	NewManifest         func() *store.ModelManifest
	NewProviderKey      func() string
	ProviderPrivateKey  func(*testing.T, string) *[32]byte
	DeleteProviderKey   func(string)
	EncryptChunk        func(*testing.T, protocol.InferenceRequestMessage, string, string) protocol.InferenceResponseChunkMessage
	PrivacyCapabilities func() *protocol.PrivacyCapabilities
}

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const huggingFaceIDMetadataKey = "hugging_face_id"

// Assert the wire contract independently of the handler's private constants.
const errorReasonDeadlineUnreachable = "deadline_unreachable"
const errorReasonCancelled = "cancelled"

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
