// Package statearchive serves the coordinator's gated state archive download.
// Snapshot consistency and archive encryption remain in package stateexport.
package statearchive

import (
	"log/slog"
	"net/http"
)

// Dependencies keep credentials and diagnostics bound to current API settings.
type Dependencies struct {
	AdminKey    func() string
	Logger      func() *slog.Logger
	BearerToken func(*http.Request) string
}

// Controller owns export authorization, response commitment and streaming.
// It retains no archive data or workers between requests.
type Controller struct {
	adminKey    func() string
	logger      func() *slog.Logger
	bearerToken func(*http.Request) string
}

func New(d Dependencies) *Controller {
	return &Controller{adminKey: d.AdminKey, logger: d.Logger, bearerToken: d.BearerToken}
}
