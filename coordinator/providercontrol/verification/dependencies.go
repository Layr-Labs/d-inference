// Package verification checks registration and device evidence for a live
// provider. Connection lifecycle and scheduled command ownership remain with
// the caller; cryptographic verification stays in the attestation package.
package verification

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry applies evidence and recovery only to the caller's live provider.
type Registry interface {
	GetProvider(string) *registry.Provider
	ProviderIDs() []string
	RestoreProviderStateContext(context.Context, *registry.Provider, *store.ProviderRecord) error
	PersistProvider(*registry.Provider)
	MarkUntrusted(string)
	DisconnectDuplicatesBySerial(string, string)
}

// Store supplies contextual reconnect reads. Trust-grant persistence remains
// behind RecordTrustReuse, which retains revocation and provider-epoch checks.
type Store interface {
	GetProviderForRestore(context.Context, string, string, []string) (*store.ProviderRecord, error)
	GetMDAChainBySerial(context.Context, string) (json.RawMessage, error)
}

type MDM interface {
	VerifyProviderWithUDIDObserver(context.Context, string, bool, bool, func(string), func(string, string)) (*mdm.VerificationResult, error)
	RequestDeviceAttestation(context.Context, string, string, time.Duration, func(string, string)) (*mdm.DeviceAttestationResponse, error)
}

// Scheduler observes transport identity on its current exact attempt. It keeps
// all durable claims, connection generations and late-command authorization.
type Scheduler interface {
	ObserveAttemptUDID(*registry.Provider, string)
	ObserveAttemptCommand(*registry.Provider, store.VerificationTaskKind, string, string)
}

// Dependencies resolve current resources and configuration at each original
// read point. Optional resources must return a nil interface when absent.
type Dependencies struct {
	Registry  func() Registry
	Store     func() Store
	MDM       func() MDM
	Scheduler func() Scheduler
	Logger    func() *slog.Logger

	BinaryHashPolicy      func() (bool, map[string]bool)
	EnforceBinaryHash     func() bool
	AllowDuplicateSerials func() bool
	NormalizeHash         func(string, string) (string, error)
	VersionLess           func(string, string) bool
	ApplicationBinaryHash func(*registry.Provider, string, string) string
	RecordTrustReuse      func(*registry.Provider, string, string, string, bool, bool, string) bool
	SendStatus            func(*registry.Provider, registry.TrustLevel, string, string)
	Incr                  func(string, []string)
}

// Verifier has no workers, inventory or connection state. A scheduled attempt
// carries its own observation record; live trust remains on registry.Provider.
type Verifier struct{ deps Dependencies }

func New(deps Dependencies) *Verifier { return &Verifier{deps: deps} }
