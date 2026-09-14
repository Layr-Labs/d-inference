package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/profilequeue"
)

type profileSink = profilequeue.Sink

func newProfileSink(s *Server, capacity int) *profileSink {
	return profilequeue.New(profilequeue.Hooks{
		Logger: s.logger,
		Build:  s.buildQueuedProfile,
		Store:  func() profilequeue.Writer { return s.store },
		Incr:   s.ddIncr,
		Count:  s.ddCount,
	}, capacity)
}

// buildQueuedProfile runs on the profile worker. The finalizing goroutine
// only enqueues; flattening, provider-profile decoding and sampling stay here.
func (s *Server) buildQueuedProfile(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	rec := s.buildProfileRecord(rp, ap)
	if rec == nil {
		return nil
	}
	if !s.profiler.alwaysRecord(rec) && !s.profiler.sampled(rp.CoordRequestID) {
		s.ddIncr("profiler.records", []string{"status:sampled_out"})
		return nil
	}
	return rec
}
