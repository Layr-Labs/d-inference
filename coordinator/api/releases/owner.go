// Package releases owns release publication, download policy and runtime hashes.
package releases

import (
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	compiledpolicy "github.com/eigeninference/d-inference/coordinator/internal/api/releases/compiledpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Hooks struct {
	BelowMinProviderVersion func(string) bool
	DDIncr                  func(string, []string)
	AppAttest               func() *attestservice.Service
	AppAttestServing        func() bool
	LatestProviderVersion   func() string
}

type Owner struct {
	registry                          *registry.Registry
	store                             store.ReleaseStore
	access                            *access.Owner
	readCache                         *readcache.Cache
	logger                            *slog.Logger
	hooks                             Hooks
	r2CDNURL                          string
	binaryHashEnforce                 bool
	releasePolicySyncMu               sync.Mutex
	binaryHashPolicyMu                sync.RWMutex
	knownBinaryHashes                 map[string]bool
	manualKnownBinaryHashes           map[string]bool
	releaseKnownBinaryHashes          map[string]bool
	manualBinaryHashPolicyConfigured  bool
	releaseBinaryHashPolicyConfigured bool
	binaryHashPolicyConfigured        bool
	releaseTrustPolicy                atomic.Pointer[compiledpolicy.Snapshot]
	releaseTrustPolicyGeneration      atomic.Uint64
	releaseInventoryEverConfigured    atomic.Bool
	runtimeManifest                   atomic.Pointer[RuntimeManifest]
	appAttestRuntimeRefreshPending    atomic.Bool
}

func New(reg *registry.Registry, st store.ReleaseStore, auth *access.Owner, cache *readcache.Cache, logger *slog.Logger, hooks Hooks) *Owner {
	s := &Owner{registry: reg, store: st, access: auth, readCache: cache, logger: logger, hooks: hooks}
	s.runtimeManifest.Store(&RuntimeManifest{})
	return s
}

func (s *Owner) SetR2CDNURL(url string)                { s.r2CDNURL = strings.TrimRight(url, "/") }
func (s *Owner) SetBinaryHashEnforcement(enabled bool) { s.binaryHashEnforce = enabled }
func (s *Owner) BinaryHashEnforced() bool              { return s.binaryHashEnforce }

func (s *Owner) ddIncr(name string, tags []string) {
	if s.hooks.DDIncr != nil {
		s.hooks.DDIncr(name, tags)
	}
}

func (s *Owner) belowMinProviderVersion(version string) bool {
	return s.hooks.BelowMinProviderVersion != nil && s.hooks.BelowMinProviderVersion(version)
}

func (s *Owner) appAttestServing() bool {
	return s.hooks.AppAttestServing != nil && s.hooks.AppAttestServing()
}
