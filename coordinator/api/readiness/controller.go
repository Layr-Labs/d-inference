// Package readiness owns coordinator ingress accounting, drain control and readiness probes.
package readiness

import (
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"
)

// Dependencies binds current server capabilities without copying their state.
type Dependencies struct {
	Logger            func() *slog.Logger
	AuthorizeAdmin    func(http.ResponseWriter, *http.Request) bool
	TrustSafetyStatus func() (bool, string)
	WriteRateLimited  func(http.ResponseWriter, string, string, time.Duration)
	MaxBodyBytes      int64
}

// Controller owns the coordinator's drain flag and count of admitted HTTP requests.
// It must not be copied after first use. Provider update draining is a separate lifecycle.
type Controller struct {
	deps                Dependencies
	httpInflight        atomic.Int64
	coordinatorDraining atomic.Bool
}

func New(deps Dependencies) *Controller { return &Controller{deps: deps} }
