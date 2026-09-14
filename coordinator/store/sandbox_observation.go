package store

import "time"

// An observation can demote a ready allocation after VM-wide cancellation or
// interrupted guest transport. It never supplies authority to start a VM.
type SandboxStoppedObservation struct {
	SandboxID, HostID           string
	Generation, FencingToken    uint64
	CPUCount                    uint16
	MemoryBytes, WorkspaceBytes uint64
	CommandTimeoutSeconds       uint32
	GPU                         bool
	LeaseExpiresAt, ObservedAt  time.Time
}

func (o SandboxStoppedObservation) matches(s *SandboxRecord) bool {
	return s != nil && s.ID == o.SandboxID && s.HostID == o.HostID && s.Generation == o.Generation && s.FencingToken == o.FencingToken &&
		s.CPUCount == o.CPUCount && s.MemoryBytes == o.MemoryBytes && s.WorkspaceBytes == o.WorkspaceBytes &&
		s.CommandTimeoutSeconds == o.CommandTimeoutSeconds && s.GPU == o.GPU && s.LeaseExpiresAt.Equal(o.LeaseExpiresAt)
}
