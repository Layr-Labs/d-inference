package session

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the current session persistence surface. Registry and MDM claim
// storage retain their separately configured persistence bindings.
type Store interface {
	GetProviderToken(string) (*store.ProviderToken, error)
	CloseProviderSession(context.Context, string, string, time.Time) error
}

// InferenceFrames preserves the synchronous accepted/chunk/error calls and the
// completion call launched after the read loop captures its ingress timestamp.
type InferenceFrames struct {
	Accepted func(*registry.Provider, *protocol.InferenceAcceptedMessage)
	Chunk    func(string, *registry.Provider, *protocol.InferenceResponseChunkMessage)
	Complete func(string, *registry.Provider, *protocol.InferenceCompleteMessage, time.Time)
	Error    func(string, *registry.Provider, *protocol.InferenceErrorMessage)
}

type LoadFailurePolicy struct {
	Classify  func(string) string
	Permanent func(string) bool
}

// Resource getters retain current API bindings. The scheduler itself keeps its
// startup claim store. CodeLoop and CodeRearm preserve the API's nil-owner guards.
type Dependencies struct {
	Registry              func() *registry.Registry
	Store                 func() Store
	Logger                func() *slog.Logger
	Challenges            func() *challenge.Session
	Verifier              func() *verification.Verifier
	Scheduler             func() *mdmscheduler.Scheduler
	TrustReuse            func() *trustreuse.Manager
	CodeIdentity          func() *codeidentity.Manager
	ReleasePolicy         func() *releasepolicy.Manager
	MinimumVersion        func() string
	Location              func(string, *registry.Provider, *http.Request)
	SupportsDesiredModels func(string, string) bool
	CodeLoop              func(context.Context, string, *registry.Provider)
	CodeRearm             func(context.Context, string, *registry.Provider, *protocol.HeartbeatMessage)
	Frames                InferenceFrames
	LoadFailure           LoadFailurePolicy
	Telemetry             Telemetry
}
