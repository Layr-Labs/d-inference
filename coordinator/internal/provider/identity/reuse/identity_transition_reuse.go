package reuse

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	coderesume "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/resume"
)

// codeTransitionReuse composes a genuine recent APNs proof with a current
// approved release. Success only sends a live resume challenge, never a grant.
type Transition struct {
	releases           *releases.Owner
	codeAttestThrottle *codeidentity.Throttle
	resume             *coderesume.Manager
	recordMetric       func(string)
	logger             *slog.Logger
}

func New(releases *releases.Owner, throttle *codeidentity.Throttle, resume *coderesume.Manager, metric func(string), logger *slog.Logger) *Transition {
	return &Transition{releases: releases, codeAttestThrottle: throttle, resume: resume, recordMetric: metric, logger: logger}
}
