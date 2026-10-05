// Package metrics emits bounded operational inference lifecycle measurements.
package metrics

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

const (
	deadlineNotApplicable = "not_applicable"
	deadlineUnknown       = "unknown"
)

type Reporter struct {
	Observation *observation.Owner
	Logger      *slog.Logger
}
