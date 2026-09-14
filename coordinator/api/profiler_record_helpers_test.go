package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	profiling "github.com/eigeninference/d-inference/coordinator/telemetry/profiler"
)

func (s *Server) buildProfileRecord(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	return (profiling.Builder{Incr: s.ddIncr}).Build(rp, ap)
}
