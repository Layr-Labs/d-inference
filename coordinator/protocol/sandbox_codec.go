package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	maxSandboxFrameBytes         = 2 * 1024 * 1024
	maxSandboxOutputBytes        = 1024 * 1024
	maxSandboxCommandInputBytes  = 1024 * 1024
	maxSandboxCommandArguments   = 256
	maxSandboxEnvironmentEntries = 128
)

const (
	sandboxGibibyte         = uint64(1024 * 1024 * 1024)
	sandboxWorkspace25GiB   = 25 * sandboxGibibyte
	sandboxWorkspace50GiB   = 50 * sandboxGibibyte
	sandboxMinimumMemory    = 2 * sandboxGibibyte
	sandboxMaximumMemory    = 512 * sandboxGibibyte
	sandboxMaximumCPU       = 64
	sandboxMaximumTimeout   = 900
	sandboxMaximumHostSlots = 2
)

var (
	sandboxIdentifierPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	sandboxErrorCodePattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	sandboxEnvironmentPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
)

type rawSandboxEnvelope struct {
	Type            string          `json:"type"`
	ProtocolVersion uint16          `json:"protocol_version"`
	HostID          string          `json:"host_id"`
	ConnectionEpoch string          `json:"connection_epoch"`
	Sequence        uint64          `json:"sequence"`
	Payload         json.RawMessage `json:"payload"`
}

func DecodeSandboxHostMessage(data []byte) (SandboxDecodedMessage, error) {
	raw, header, err := decodeSandboxEnvelope(data)
	if err != nil {
		return SandboxDecodedMessage{}, err
	}
	var payload any
	switch header.Type {
	case SandboxTypeHostRegister:
		payload = &SandboxHostRegisterPayload{}
	case SandboxTypeHostHeartbeat:
		payload = &SandboxHostHeartbeatPayload{}
	case SandboxTypeOperationState:
		payload = &SandboxOperationStatePayload{}
	case SandboxTypeCommandState:
		payload = &SandboxCommandStatePayload{}
	case SandboxTypeHostFailure:
		payload = &SandboxHostFailurePayload{}
	default:
		return SandboxDecodedMessage{}, fmt.Errorf(
			"unsupported sandbox host message type %q",
			header.Type,
		)
	}
	if err := strictSandboxJSON(raw.Payload, payload); err != nil {
		return SandboxDecodedMessage{}, fmt.Errorf("decode %s payload: %w", header.Type, err)
	}
	if err := validateSandboxHostPayload(header.Type, payload); err != nil {
		return SandboxDecodedMessage{}, err
	}
	return SandboxDecodedMessage{Header: header, Payload: payload}, nil
}

func DecodeSandboxCoordinatorMessage(data []byte) (SandboxDecodedMessage, error) {
	raw, header, err := decodeSandboxEnvelope(data)
	if err != nil {
		return SandboxDecodedMessage{}, err
	}
	var payload any
	switch header.Type {
	case SandboxTypePrepare:
		payload = &SandboxPreparePayload{}
	case SandboxTypeLeaseRenew:
		payload = &SandboxLeaseRenewPayload{}
	case SandboxTypeCommand:
		payload = &SandboxCommandPayload{}
	case SandboxTypeCancelCommand:
		payload = &SandboxCommandControlPayload{}
	case SandboxTypeStop, SandboxTypeDelete:
		payload = &SandboxOperationPayload{}
	case SandboxTypeDrain:
		payload = &SandboxDrainPayload{}
	default:
		return SandboxDecodedMessage{}, fmt.Errorf(
			"unsupported sandbox coordinator message type %q",
			header.Type,
		)
	}
	if err := strictSandboxJSON(raw.Payload, payload); err != nil {
		return SandboxDecodedMessage{}, fmt.Errorf("decode %s payload: %w", header.Type, err)
	}
	if err := validateSandboxCoordinatorPayload(header.Type, payload); err != nil {
		return SandboxDecodedMessage{}, err
	}
	return SandboxDecodedMessage{Header: header, Payload: payload}, nil
}

func decodeSandboxEnvelope(
	data []byte,
) (rawSandboxEnvelope, SandboxMessageHeader, error) {
	if len(data) == 0 || len(data) > maxSandboxFrameBytes {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, errors.New(
			"sandbox frame size is invalid",
		)
	}
	if err := rejectDuplicateSandboxJSONKeys(data); err != nil {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, err
	}
	var raw rawSandboxEnvelope
	if err := strictSandboxJSON(data, &raw); err != nil {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, fmt.Errorf(
			"decode sandbox envelope: %w",
			err,
		)
	}
	header := SandboxMessageHeader{
		Type:            raw.Type,
		ProtocolVersion: raw.ProtocolVersion,
		HostID:          raw.HostID,
		ConnectionEpoch: raw.ConnectionEpoch,
		Sequence:        raw.Sequence,
	}
	if header.Type == "" ||
		header.ProtocolVersion != SandboxProtocolVersion ||
		uuid.Validate(header.HostID) != nil ||
		uuid.Validate(header.ConnectionEpoch) != nil ||
		header.Sequence == 0 ||
		len(raw.Payload) == 0 ||
		bytes.Equal(raw.Payload, []byte("null")) {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, errors.New(
			"sandbox envelope is invalid",
		)
	}
	return raw, header, nil
}

func strictSandboxJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func rejectDuplicateSandboxJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var walk func() error
	walk = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delimiter, isDelimiter := token.(json.Delim)
		if !isDelimiter {
			return nil
		}
		switch delimiter {
		case '{':
			seen := make(map[string]struct{})
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok {
					return errors.New("JSON object key is not a string")
				}
				if _, exists := seen[key]; exists {
					return fmt.Errorf("duplicate JSON key %q", key)
				}
				seen[key] = struct{}{}
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case '[':
			for decoder.More() {
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		default:
			return errors.New("unexpected JSON delimiter")
		}
	}
	if err := walk(); err != nil {
		return fmt.Errorf("invalid sandbox JSON: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("sandbox frame contains trailing JSON")
	}
	return nil
}

func validateSandboxHostPayload(messageType string, payload any) error {
	switch value := payload.(type) {
	case *SandboxHostRegisterPayload:
		capabilities := value.Capabilities
		if !sandboxIdentifierPattern.MatchString(capabilities.DaemonVersion) ||
			capabilities.OperatingSystem != "macos" ||
			capabilities.Architecture != "arm64" ||
			strings.TrimSpace(capabilities.MachineModel) == "" ||
			strings.TrimSpace(capabilities.ChipName) == "" ||
			capabilities.CPUCount == 0 ||
			capabilities.MemoryBytes < sandboxMinimumMemory ||
			capabilities.MaximumSandboxes == 0 ||
			capabilities.MaximumSandboxes > sandboxMaximumHostSlots ||
			!validWorkspaceSizes(capabilities.WorkspaceSizesBytes) {
			return errors.New("sandbox host capabilities are invalid")
		}
	case *SandboxHostHeartbeatPayload:
		if value.Mode != "sandbox_dedicated" && value.Mode != "draining" {
			return errors.New("sandbox host mode is invalid")
		}
		if len(value.Leases) > sandboxMaximumHostSlots {
			return errors.New("sandbox host reported too many leases")
		}
		for index := range value.Leases {
			lease := &value.Leases[index]
			if err := validateSandboxScope(lease.Scope); err != nil {
				return err
			}
			if err := validateSandboxResources(lease.Resources); err != nil {
				return err
			}
			if !knownSandboxOperationState(lease.State) ||
				validateSandboxTimestamp(lease.LeaseExpiresAt) != nil {
				return errors.New("sandbox host lease observation is invalid")
			}
		}
	case *SandboxOperationStatePayload:
		if uuid.Validate(value.OperationID) != nil ||
			validateSandboxScope(value.Scope) != nil ||
			!knownSandboxOperation(value.Operation) ||
			!knownSandboxOperationState(value.State) ||
			!validOptionalSandboxErrorCode(value.ErrorCode) {
			return errors.New("sandbox operation state is invalid")
		}
	case *SandboxCommandStatePayload:
		if uuid.Validate(value.CommandID) != nil ||
			validateSandboxScope(value.Scope) != nil ||
			!knownSandboxCommandState(value.State) ||
			!validOptionalSandboxErrorCode(value.ErrorCode) ||
			len(value.StandardOutput) > maxSandboxOutputBytes ||
			len(value.StandardError) > maxSandboxOutputBytes {
			return errors.New("sandbox command state is invalid")
		}
		if (value.State == SandboxCommandSucceeded ||
			value.State == SandboxCommandFailed) && value.ExitCode == nil {
			return errors.New("terminal sandbox command is missing exit code")
		}
	case *SandboxHostFailurePayload:
		if (value.OperationID == "" && value.CommandID == "") ||
			(value.OperationID != "" && uuid.Validate(value.OperationID) != nil) ||
			(value.CommandID != "" && uuid.Validate(value.CommandID) != nil) ||
			(value.Scope != nil && validateSandboxScope(*value.Scope) != nil) ||
			!sandboxErrorCodePattern.MatchString(value.ErrorCode) {
			return errors.New("sandbox host failure is invalid")
		}
	default:
		return fmt.Errorf("unexpected %s payload", messageType)
	}
	return nil
}

func validateSandboxCoordinatorPayload(messageType string, payload any) error {
	switch value := payload.(type) {
	case *SandboxPreparePayload:
		if uuid.Validate(value.OperationID) != nil ||
			validateSandboxScope(value.Scope) != nil ||
			validateSandboxResources(value.Resources) != nil ||
			!sandboxIdentifierPattern.MatchString(value.BaseImageID) ||
			validateSandboxTimestamp(value.LeaseExpiresAt) != nil {
			return errors.New("sandbox prepare payload is invalid")
		}
	case *SandboxLeaseRenewPayload:
		if uuid.Validate(value.OperationID) != nil ||
			validateSandboxScope(value.Scope) != nil ||
			validateSandboxTimestamp(value.LeaseExpiresAt) != nil {
			return errors.New("sandbox lease renewal is invalid")
		}
	case *SandboxCommandPayload:
		if err := validateSandboxCommand(value); err != nil {
			return err
		}
	case *SandboxCommandControlPayload:
		if uuid.Validate(value.OperationID) != nil ||
			uuid.Validate(value.CommandID) != nil ||
			validateSandboxScope(value.Scope) != nil {
			return errors.New("sandbox command control payload is invalid")
		}
	case *SandboxOperationPayload:
		if uuid.Validate(value.OperationID) != nil ||
			validateSandboxScope(value.Scope) != nil {
			return errors.New("sandbox operation payload is invalid")
		}
	case *SandboxDrainPayload:
		if uuid.Validate(value.OperationID) != nil ||
			strings.TrimSpace(value.Reason) == "" ||
			len(value.Reason) > 256 {
			return errors.New("sandbox drain payload is invalid")
		}
	default:
		return fmt.Errorf("unexpected %s payload", messageType)
	}
	return nil
}

func validateSandboxScope(scope SandboxScope) error {
	if uuid.Validate(scope.SandboxID) != nil ||
		scope.Generation == 0 ||
		scope.FencingToken == 0 {
		return errors.New("sandbox operation scope is invalid")
	}
	return nil
}

func validateSandboxResources(resources SandboxResources) error {
	if resources.CPUCount == 0 ||
		resources.CPUCount > sandboxMaximumCPU ||
		resources.MemoryBytes < sandboxMinimumMemory ||
		resources.MemoryBytes > sandboxMaximumMemory ||
		(resources.WorkspaceBytes != sandboxWorkspace25GiB &&
			resources.WorkspaceBytes != sandboxWorkspace50GiB) ||
		resources.CommandTimeoutSeconds == 0 ||
		resources.CommandTimeoutSeconds > sandboxMaximumTimeout {
		return errors.New("sandbox resources are invalid")
	}
	return nil
}

func validateSandboxCommand(command *SandboxCommandPayload) error {
	if uuid.Validate(command.CommandID) != nil ||
		!sandboxIdentifierPattern.MatchString(command.IdempotencyKey) ||
		validateSandboxScope(command.Scope) != nil ||
		len(command.Arguments) == 0 ||
		len(command.Arguments) > maxSandboxCommandArguments ||
		len(command.Environment) > maxSandboxEnvironmentEntries ||
		command.TimeoutSeconds == 0 ||
		command.TimeoutSeconds > sandboxMaximumTimeout {
		return errors.New("sandbox command payload is invalid")
	}
	totalBytes := 0
	for _, argument := range command.Arguments {
		if strings.ContainsRune(argument, '\x00') {
			return errors.New("sandbox command argument contains NUL")
		}
		totalBytes += len(argument)
	}
	for key, value := range command.Environment {
		if !sandboxEnvironmentPattern.MatchString(key) ||
			strings.ContainsRune(value, '\x00') {
			return errors.New("sandbox command environment is invalid")
		}
		totalBytes += len(key) + len(value)
	}
	if command.WorkingDirectory != "" {
		if !path.IsAbs(command.WorkingDirectory) ||
			path.Clean(command.WorkingDirectory) != command.WorkingDirectory ||
			strings.ContainsRune(command.WorkingDirectory, '\x00') {
			return errors.New("sandbox command working directory is invalid")
		}
		totalBytes += len(command.WorkingDirectory)
	}
	if totalBytes > maxSandboxCommandInputBytes {
		return errors.New("sandbox command input is too large")
	}
	return nil
}

func validWorkspaceSizes(sizes []uint64) bool {
	if len(sizes) == 0 || len(sizes) > 2 {
		return false
	}
	seen := make(map[uint64]struct{}, len(sizes))
	for _, size := range sizes {
		if size != sandboxWorkspace25GiB && size != sandboxWorkspace50GiB {
			return false
		}
		if _, duplicate := seen[size]; duplicate {
			return false
		}
		seen[size] = struct{}{}
	}
	return true
}

func validateSandboxTimestamp(value string) error {
	if value == "" {
		return errors.New("sandbox timestamp is empty")
	}
	_, err := time.Parse(time.RFC3339Nano, value)
	return err
}

func validOptionalSandboxErrorCode(value string) bool {
	return value == "" || sandboxErrorCodePattern.MatchString(value)
}

func knownSandboxOperation(value string) bool {
	switch value {
	case "prepare", "stop", "delete":
		return true
	default:
		return false
	}
}

func knownSandboxOperationState(value string) bool {
	switch value {
	case SandboxOperationPreparing,
		SandboxOperationBooting,
		SandboxOperationReady,
		SandboxOperationStopping,
		SandboxOperationStopped,
		SandboxOperationDeleting,
		SandboxOperationDeleted,
		SandboxOperationFailed:
		return true
	default:
		return false
	}
}

func knownSandboxCommandState(value string) bool {
	switch value {
	case SandboxCommandAccepted,
		SandboxCommandRunning,
		SandboxCommandSucceeded,
		SandboxCommandFailed,
		SandboxCommandTimedOut,
		SandboxCommandCancelled,
		SandboxCommandLost:
		return true
	default:
		return false
	}
}
