package providerframe

import "sync/atomic"

// Service owns provider inference-frame processing and its private decryption
// cache. Pending attempts, cancellation and settlement keep their shared owners.
type Service struct {
	deps                 Dependencies
	chunkKeys            chunkKeyCache
	unknownRequestFrames atomic.Int64
}

func New(deps Dependencies) *Service { return &Service{deps: deps} }

// UnknownRequestFrames supplies the existing cumulative fleet-sample counter.
func (s *Service) UnknownRequestFrames() int64 { return s.unknownRequestFrames.Load() }

const (
	unknownFrameKindComplete = "complete"
	unknownFrameKindError    = "error"
)
