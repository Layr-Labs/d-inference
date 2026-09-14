package store

import "time"

// SandboxCommandSummary is bounded metadata for command-history navigation.
// Arguments, environment and potentially large output are only returned by the
// account-scoped GetSandboxCommand endpoint.
type SandboxCommandSummary struct {
	ID                  string     `json:"id"`
	SandboxID           string     `json:"sandbox_id"`
	State               string     `json:"state"`
	TimeoutSeconds      uint32     `json:"timeout_seconds"`
	ExitCode            *int32     `json:"exit_code,omitempty"`
	ErrorCode           string     `json:"error_code,omitempty"`
	OutputTruncated     bool       `json:"output_truncated"`
	CancellationPending bool       `json:"cancellation_pending"`
	CreatedAt           time.Time  `json:"created_at"`
	StartedAt           *time.Time `json:"started_at,omitempty"`
	CompletedAt         *time.Time `json:"completed_at,omitempty"`
	PayloadExpired      bool       `json:"payload_expired"`
	PayloadExpiredAt    *time.Time `json:"payload_expired_at,omitempty"`
}

func sandboxCommandSummary(command *SandboxCommand) SandboxCommandSummary {
	return SandboxCommandSummary{
		ID:                  command.ID,
		SandboxID:           command.SandboxID,
		State:               command.State,
		TimeoutSeconds:      command.TimeoutSeconds,
		ExitCode:            cloneInt32(command.ExitCode),
		ErrorCode:           command.ErrorCode,
		OutputTruncated:     command.OutputTruncated,
		CancellationPending: command.CancellationPending,
		CreatedAt:           command.CreatedAt,
		StartedAt:           cloneTimePtr(command.StartedAt),
		CompletedAt:         cloneTimePtr(command.CompletedAt),
		PayloadExpired:      command.PayloadExpired,
		PayloadExpiredAt:    cloneTimePtr(command.PayloadExpiredAt),
	}
}
