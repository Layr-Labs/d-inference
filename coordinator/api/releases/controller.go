// Package releases serves provider release registration, discovery and retirement.
// Artifact verification and request/cache behavior live here; trusted runtime
// decisions and fleet revalidation remain with releasepolicy.Manager.
package releases

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the release inventory's existing read and mutation boundary.
type Store interface {
	SetRelease(*store.Release) error
	DeleteRelease(string, string) error
	GetLatestRelease(string) *store.Release
	ListReleasesWithError() ([]store.Release, error)
}

// Cache holds the existing serialized public reads shared with the API.
type Cache interface {
	Get(string) ([]byte, bool)
	Set(string, []byte, time.Duration)
	Invalidate(string)
}

// Dependencies resolve current API settings and resources at request time.
type Dependencies struct {
	Store              func() Store
	Cache              func() Cache
	Policy             func() *releasepolicy.Manager
	Logger             func() *slog.Logger
	ReleaseKey         func() string
	CDNURL             func() string
	BinaryHashEnforced func() bool
	ProvidersWithHash  func(string) int
	AuthorizeAdmin     func(http.ResponseWriter, *http.Request) bool
	BearerToken        func(*http.Request) string
}

// Controller owns release request validation, artifact checks and publication
// responses. It starts no workers and retains no inventory or trust-policy copy.
type Controller struct {
	store              func() Store
	cache              func() Cache
	policy             func() *releasepolicy.Manager
	logger             func() *slog.Logger
	releaseKey         func() string
	cdnURL             func() string
	binaryHashEnforced func() bool
	providersWithHash  func(string) int
	authorizeAdmin     func(http.ResponseWriter, *http.Request) bool
	bearerToken        func(*http.Request) string
}

func New(d Dependencies) *Controller {
	return &Controller{
		store:              d.Store,
		cache:              d.Cache,
		policy:             d.Policy,
		logger:             d.Logger,
		releaseKey:         d.ReleaseKey,
		cdnURL:             d.CDNURL,
		binaryHashEnforced: d.BinaryHashEnforced,
		providersWithHash:  d.ProvidersWithHash,
		authorizeAdmin:     d.AuthorizeAdmin,
		bearerToken:        d.BearerToken,
	}
}
