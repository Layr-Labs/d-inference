package protocol

const SandboxProtocolVersion uint16 = 1

const (
	// Sandbox host → coordinator.
	SandboxTypeHostRegister   = "sandbox_host_register"
	SandboxTypeHostHeartbeat  = "sandbox_host_heartbeat"
	SandboxTypeOperationState = "sandbox_operation_state"
	SandboxTypeCommandState   = "sandbox_command_state"
	SandboxTypeHostFailure    = "sandbox_host_failure"

	// Coordinator → sandbox host.
	SandboxTypePrepare       = "sandbox_prepare"
	SandboxTypeLeaseRenew    = "sandbox_lease_renew"
	SandboxTypeCommand       = "sandbox_command"
	SandboxTypeCancelCommand = "sandbox_cancel_command"
	SandboxTypeStop          = "sandbox_stop"
	SandboxTypeDelete        = "sandbox_delete"
	SandboxTypeDrain         = "sandbox_drain"
)

const (
	SandboxOperationPreparing = "preparing"
	SandboxOperationBooting   = "booting"
	SandboxOperationReady     = "ready"
	SandboxOperationStopping  = "stopping"
	SandboxOperationStopped   = "stopped"
	SandboxOperationDeleting  = "deleting"
	SandboxOperationDeleted   = "deleted"
	SandboxOperationFailed    = "failed"
)

const (
	SandboxCommandAccepted  = "accepted"
	SandboxCommandRunning   = "running"
	SandboxCommandSucceeded = "succeeded"
	SandboxCommandFailed    = "failed"
	SandboxCommandTimedOut  = "timed_out"
	SandboxCommandCancelled = "cancelled"
	SandboxCommandLost      = "lost"
)

// SandboxEnvelope is the versioned frame shared by the coordinator and the
// dedicated macOS sandbox host connection. Authentication is carried by the
// WebSocket HTTP upgrade, never in the frame.
type SandboxEnvelope[Payload any] struct {
	Type            string  `json:"type"`
	ProtocolVersion uint16  `json:"protocol_version"`
	HostID          string  `json:"host_id"`
	ConnectionEpoch string  `json:"connection_epoch"`
	Sequence        uint64  `json:"sequence"`
	Payload         Payload `json:"payload"`
}

type SandboxMessageHeader struct {
	Type            string
	ProtocolVersion uint16
	HostID          string
	ConnectionEpoch string
	Sequence        uint64
}

type SandboxDecodedMessage struct {
	Header  SandboxMessageHeader
	Payload any
}

type SandboxHostCapabilities struct {
	DaemonVersion       string   `json:"daemon_version"`
	OperatingSystem     string   `json:"operating_system"`
	Architecture        string   `json:"architecture"`
	MachineModel        string   `json:"machine_model"`
	ChipName            string   `json:"chip_name"`
	CPUCount            uint16   `json:"cpu_count"`
	MemoryBytes         uint64   `json:"memory_bytes"`
	MaximumSandboxes    uint16   `json:"maximum_sandboxes"`
	WorkspaceSizesBytes []uint64 `json:"workspace_sizes_bytes"`
	BaseImageIDs        []string `json:"base_image_ids"`
	SupportsGPU         bool     `json:"supports_gpu"`
}

type SandboxHostRegisterPayload struct {
	Capabilities SandboxHostCapabilities `json:"capabilities"`
}

type SandboxScope struct {
	SandboxID    string `json:"sandbox_id"`
	Generation   uint64 `json:"generation"`
	FencingToken uint64 `json:"fencing_token"`
}

type SandboxResources struct {
	CPUCount              uint16 `json:"cpu_count"`
	MemoryBytes           uint64 `json:"memory_bytes"`
	WorkspaceBytes        uint64 `json:"workspace_bytes"`
	CommandTimeoutSeconds uint32 `json:"command_timeout_seconds"`
	GPU                   bool   `json:"gpu"`
}

type SandboxHostLeaseObservation struct {
	Scope          SandboxScope     `json:"scope"`
	State          string           `json:"state"`
	Resources      SandboxResources `json:"resources"`
	LeaseExpiresAt string           `json:"lease_expires_at"`
}

type SandboxHostHeartbeatPayload struct {
	Mode             string                        `json:"mode"`
	AvailableCPU     uint16                        `json:"available_cpu"`
	AvailableMemory  uint64                        `json:"available_memory_bytes"`
	NextFencingToken uint64                        `json:"next_fencing_token"`
	Leases           []SandboxHostLeaseObservation `json:"leases"`
}

type SandboxOperationStatePayload struct {
	OperationID string       `json:"operation_id"`
	Scope       SandboxScope `json:"scope"`
	Operation   string       `json:"operation"`
	State       string       `json:"state"`
	ErrorCode   *string      `json:"error_code,omitempty"`
}

type SandboxCommandStatePayload struct {
	CommandID       string       `json:"command_id"`
	Scope           SandboxScope `json:"scope"`
	State           string       `json:"state"`
	ExitCode        *int32       `json:"exit_code,omitempty"`
	StandardOutput  *string      `json:"stdout,omitempty"`
	StandardError   *string      `json:"stderr,omitempty"`
	OutputTruncated bool         `json:"output_truncated"`
	ErrorCode       *string      `json:"error_code,omitempty"`
}

type SandboxHostFailurePayload struct {
	OperationID *string       `json:"operation_id,omitempty"`
	CommandID   *string       `json:"command_id,omitempty"`
	Scope       *SandboxScope `json:"scope,omitempty"`
	ErrorCode   string        `json:"error_code"`
}

type SandboxPreparePayload struct {
	OperationID    string           `json:"operation_id"`
	Scope          SandboxScope     `json:"scope"`
	Resources      SandboxResources `json:"resources"`
	BaseImageID    string           `json:"base_image_id"`
	LeaseExpiresAt string           `json:"lease_expires_at"`
}

type SandboxLeaseRenewPayload struct {
	OperationID    string       `json:"operation_id"`
	Scope          SandboxScope `json:"scope"`
	LeaseExpiresAt string       `json:"lease_expires_at"`
}

type SandboxCommandPayload struct {
	CommandID        string            `json:"command_id"`
	IdempotencyKey   string            `json:"idempotency_key"`
	Scope            SandboxScope      `json:"scope"`
	Arguments        []string          `json:"arguments"`
	Environment      map[string]string `json:"environment,omitempty"`
	WorkingDirectory *string           `json:"working_directory,omitempty"`
	TimeoutSeconds   uint32            `json:"timeout_seconds"`
}

type SandboxCommandControlPayload struct {
	OperationID string       `json:"operation_id"`
	CommandID   string       `json:"command_id"`
	Scope       SandboxScope `json:"scope"`
}

type SandboxOperationPayload struct {
	OperationID string       `json:"operation_id"`
	Scope       SandboxScope `json:"scope"`
}

type SandboxDrainPayload struct {
	OperationID string `json:"operation_id"`
	Reason      string `json:"reason"`
}
