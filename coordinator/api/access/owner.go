package access

import (
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the persistence surface used by credential authentication.
type Store interface {
	FindPublishingAPIKeysWithError() ([]store.PublishingAPIKey, error)
	MarkPublishingAPIKeyUsed(string) error
	AuthenticateKey(string) (*store.APIKey, error)
	TouchAPIKey(string, time.Time)
	GetProviderToken(string) (*store.ProviderToken, error)
	GetUserByAccountID(string) (*store.User, error)
	MigrateAccountBalance(string, string) (bool, error)
}

// Hooks connect authentication to request observation without transport ownership.
type Hooks struct {
	SetOutcomeStage func(*http.Request, string)
	StampAuth       func(*http.Request, string, bool)
}

// Owner owns credential policy, principal authentication and its cache.
// Configure its policies before serving requests.
type Owner struct {
	rateLimiter           *ratelimit.Limiter
	financialRateLimiter  *ratelimit.Limiter
	serviceRateLimiter    *ratelimit.Limiter
	keyRPMLimiter         *ratelimit.Limiter
	rateIncr              func(string, []string)
	rateStamp             func(*http.Request)
	store                 Store
	logger                *slog.Logger
	privyAuth             *auth.PrivyAuth
	adminKey              string
	adminEmails           map[string]bool
	releaseKey            string
	controlPlaneBodyBytes int64
	hooks                 Hooks
	// apiKeyCache memoizes AuthenticateKey results so repeated requests
	// with the same API key skip the DB round trip. Entries expire after
	// apiKeyCacheTTL. Bounded at apiKeyCacheMaxSize entries.
	apiKeyCacheMu sync.RWMutex
	apiKeyCache   map[string]apiKeyCacheEntry
	// apiKeyCacheGen is bumped on every key mutation. A cached entry is only
	// honored when its gen matches, so a single bump atomically invalidates the
	// whole cache and closes the read-stale-after-mutation race.
	apiKeyCacheGen uint64
}

func New(st Store, logger *slog.Logger, controlPlaneBodyBytes int64, hooks Hooks) *Owner {
	return &Owner{store: st, logger: logger, controlPlaneBodyBytes: controlPlaneBodyBytes, hooks: hooks, apiKeyCache: make(map[string]apiKeyCacheEntry)}
}

func (s *Owner) SetPrivyAuth(pa *auth.PrivyAuth)        { s.privyAuth = pa }
func (s *Owner) SetKeyRPMLimiter(rl *ratelimit.Limiter) { s.keyRPMLimiter = rl }
func (s *Owner) SetRateObservation(incr func(string, []string), stamp func(*http.Request)) {
	s.rateIncr, s.rateStamp = incr, stamp
}
func (s *Owner) countRateLimit(name string, tags []string) {
	if s.rateIncr != nil {
		s.rateIncr(name, tags)
	}
}
func (s *Owner) stampRateLimit(r *http.Request) {
	if s.rateStamp != nil {
		s.rateStamp(r)
	}
}
func (s *Owner) SetAdminKey(key string)   { s.adminKey = key }
func (s *Owner) SetReleaseKey(key string) { s.releaseKey = key }
func (s *Owner) SetAdminEmails(emails []string) {
	s.adminEmails = make(map[string]bool, len(emails))
	for _, e := range emails {
		s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
	}
}

func (s *Owner) setOutcomeStage(r *http.Request, stage string) {
	if s.hooks.SetOutcomeStage != nil {
		s.hooks.SetOutcomeStage(r, stage)
	}
}
func (s *Owner) stampAuth(r *http.Request, kind string, dbRead bool) {
	if s.hooks.StampAuth != nil {
		s.hooks.StampAuth(r, kind, dbRead)
	}
}
