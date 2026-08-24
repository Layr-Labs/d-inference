package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"reflect"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

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
	if !utf8.Valid(data) {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, errors.New(
			"sandbox frame is not valid UTF-8",
		)
	}
	if err := rejectInvalidSandboxUnicodeEscapes(data); err != nil {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, err
	}
	if err := rejectDuplicateSandboxJSONKeys(data); err != nil {
		return rawSandboxEnvelope{}, SandboxMessageHeader{}, err
	}
	if err := requireExactSandboxJSONFields(
		data,
		reflect.TypeOf(rawSandboxEnvelope{}),
	); err != nil {
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
		!validCanonicalSandboxUUID(header.HostID) ||
		!validCanonicalSandboxUUID(header.ConnectionEpoch) ||
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
	targetType := reflect.TypeOf(target)
	if targetType == nil {
		return errors.New("sandbox JSON target is nil")
	}
	if err := requireExactSandboxJSONFields(data, targetType); err != nil {
		return err
	}
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

func requireExactSandboxJSONFields(data []byte, targetType reflect.Type) error {
	for targetType.Kind() == reflect.Pointer {
		targetType = targetType.Elem()
	}
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		return errors.New("sandbox JSON value must not be null")
	}
	switch targetType.Kind() {
	case reflect.Struct:
		var object map[string]json.RawMessage
		if err := json.Unmarshal(data, &object); err != nil {
			return err
		}
		fields := make(map[string]reflect.StructField)
		required := make(map[string]struct{})
		for index := 0; index < targetType.NumField(); index++ {
			field := targetType.Field(index)
			if !field.IsExported() {
				continue
			}
			tagParts := strings.Split(field.Tag.Get("json"), ",")
			name := tagParts[0]
			if name == "-" {
				continue
			}
			if name == "" {
				name = field.Name
			}
			fields[name] = field
			optional := false
			for _, option := range tagParts[1:] {
				optional = optional || option == "omitempty"
			}
			if !optional {
				required[name] = struct{}{}
			}
		}
		for name := range required {
			if _, present := object[name]; !present {
				return fmt.Errorf("required sandbox JSON field %q is missing", name)
			}
		}
		for name, raw := range object {
			field, known := fields[name]
			if !known {
				return fmt.Errorf("unknown sandbox JSON field %q", name)
			}
			if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				return fmt.Errorf("sandbox JSON field %q must not be null", name)
			}
			if err := requireExactSandboxJSONFields(raw, field.Type); err != nil {
				return fmt.Errorf("sandbox JSON field %q: %w", name, err)
			}
		}
	case reflect.Slice, reflect.Array:
		if targetType == reflect.TypeOf(json.RawMessage{}) {
			return nil
		}
		var elements []json.RawMessage
		if err := json.Unmarshal(data, &elements); err != nil {
			return err
		}
		for index, element := range elements {
			if err := requireExactSandboxJSONFields(
				element,
				targetType.Elem(),
			); err != nil {
				return fmt.Errorf("sandbox JSON element %d: %w", index, err)
			}
		}
	case reflect.Map:
		if targetType.Key().Kind() != reflect.String {
			return errors.New("sandbox JSON map key must be a string")
		}
		var entries map[string]json.RawMessage
		if err := json.Unmarshal(data, &entries); err != nil {
			return err
		}
		for name, raw := range entries {
			if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				return fmt.Errorf("sandbox JSON map value %q must not be null", name)
			}
			if err := requireExactSandboxJSONFields(
				raw,
				targetType.Elem(),
			); err != nil {
				return fmt.Errorf("sandbox JSON map value %q: %w", name, err)
			}
		}
	default:
		var value any
		if err := json.Unmarshal(data, &value); err != nil {
			return err
		}
	}
	return nil
}

func rejectDuplicateSandboxJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 64 {
			return errors.New("sandbox JSON nesting exceeds 64 levels")
		}
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
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case '[':
			for decoder.More() {
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		default:
			return errors.New("unexpected JSON delimiter")
		}
	}
	if err := walk(0); err != nil {
		return fmt.Errorf("invalid sandbox JSON: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("sandbox frame contains trailing JSON")
	}
	return nil
}

func rejectInvalidSandboxUnicodeEscapes(data []byte) error {
	for index := 0; index < len(data); index++ {
		if data[index] != '"' {
			continue
		}
		index++
		for index < len(data) && data[index] != '"' {
			if data[index] != '\\' {
				index++
				continue
			}
			index++
			if index >= len(data) {
				return errors.New("unterminated sandbox JSON escape")
			}
			if data[index] != 'u' {
				index++
				continue
			}
			codeUnit, ok := sandboxHexCodeUnit(data, index+1)
			if !ok {
				return errors.New("invalid sandbox JSON Unicode escape")
			}
			index += 4
			switch {
			case codeUnit >= 0xD800 && codeUnit <= 0xDBFF:
				if index+6 >= len(data) ||
					data[index+1] != '\\' ||
					data[index+2] != 'u' {
					return errors.New("unpaired sandbox JSON high surrogate")
				}
				low, ok := sandboxHexCodeUnit(data, index+3)
				if !ok || low < 0xDC00 || low > 0xDFFF {
					return errors.New("unpaired sandbox JSON high surrogate")
				}
				index += 6
			case codeUnit >= 0xDC00 && codeUnit <= 0xDFFF:
				return errors.New("unpaired sandbox JSON low surrogate")
			}
			index++
		}
	}
	return nil
}

func sandboxHexCodeUnit(data []byte, start int) (uint16, bool) {
	if start < 0 || start+4 > len(data) {
		return 0, false
	}
	var value uint16
	for _, character := range data[start : start+4] {
		value <<= 4
		switch {
		case character >= '0' && character <= '9':
			value += uint16(character - '0')
		case character >= 'a' && character <= 'f':
			value += uint16(character-'a') + 10
		case character >= 'A' && character <= 'F':
			value += uint16(character-'A') + 10
		default:
			return 0, false
		}
	}
	return value, true
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
		if !validCanonicalSandboxUUID(value.OperationID) ||
			validateSandboxScope(value.Scope) != nil ||
			!knownSandboxOperation(value.Operation) ||
			!knownSandboxOperationState(value.State) ||
			!validOptionalSandboxErrorCode(value.ErrorCode) {
			return errors.New("sandbox operation state is invalid")
		}
	case *SandboxCommandStatePayload:
		if !validCanonicalSandboxUUID(value.CommandID) ||
			validateSandboxScope(value.Scope) != nil ||
			!knownSandboxCommandState(value.State) ||
			!validOptionalSandboxErrorCode(value.ErrorCode) ||
			optionalSandboxStringBytes(value.StandardOutput) > maxSandboxOutputBytes ||
			optionalSandboxStringBytes(value.StandardError) > maxSandboxOutputBytes {
			return errors.New("sandbox command state is invalid")
		}
		if (value.State == SandboxCommandSucceeded ||
			value.State == SandboxCommandFailed) && value.ExitCode == nil {
			return errors.New("terminal sandbox command is missing exit code")
		}
	case *SandboxHostFailurePayload:
		if (value.OperationID == nil && value.CommandID == nil) ||
			(value.OperationID != nil &&
				!validCanonicalSandboxUUID(*value.OperationID)) ||
			(value.CommandID != nil &&
				!validCanonicalSandboxUUID(*value.CommandID)) ||
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
		if !validCanonicalSandboxUUID(value.OperationID) ||
			validateSandboxScope(value.Scope) != nil ||
			validateSandboxResources(value.Resources) != nil ||
			!sandboxIdentifierPattern.MatchString(value.BaseImageID) ||
			validateSandboxTimestamp(value.LeaseExpiresAt) != nil {
			return errors.New("sandbox prepare payload is invalid")
		}
	case *SandboxLeaseRenewPayload:
		if !validCanonicalSandboxUUID(value.OperationID) ||
			validateSandboxScope(value.Scope) != nil ||
			validateSandboxTimestamp(value.LeaseExpiresAt) != nil {
			return errors.New("sandbox lease renewal is invalid")
		}
	case *SandboxCommandPayload:
		if err := validateSandboxCommand(value); err != nil {
			return err
		}
	case *SandboxCommandControlPayload:
		if !validCanonicalSandboxUUID(value.OperationID) ||
			!validCanonicalSandboxUUID(value.CommandID) ||
			validateSandboxScope(value.Scope) != nil {
			return errors.New("sandbox command control payload is invalid")
		}
	case *SandboxOperationPayload:
		if !validCanonicalSandboxUUID(value.OperationID) ||
			validateSandboxScope(value.Scope) != nil {
			return errors.New("sandbox operation payload is invalid")
		}
	case *SandboxDrainPayload:
		if !validCanonicalSandboxUUID(value.OperationID) ||
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
	if !validCanonicalSandboxUUID(scope.SandboxID) ||
		scope.Generation == 0 ||
		scope.FencingToken == 0 {
		return errors.New("sandbox operation scope is invalid")
	}
	return nil
}

func validCanonicalSandboxUUID(value string) bool {
	if len(value) != 36 ||
		value[8] != '-' ||
		value[13] != '-' ||
		value[18] != '-' ||
		value[23] != '-' {
		return false
	}
	_, err := uuid.Parse(value)
	return err == nil
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
	if !validCanonicalSandboxUUID(command.CommandID) ||
		!sandboxIdentifierPattern.MatchString(command.IdempotencyKey) ||
		validateSandboxScope(command.Scope) != nil ||
		len(command.Arguments) == 0 ||
		len(command.Arguments) > maxSandboxCommandArguments ||
		len(command.Environment) > maxSandboxEnvironmentEntries ||
		(command.Environment != nil && len(command.Environment) == 0) ||
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
	if command.WorkingDirectory != nil {
		workingDirectory := *command.WorkingDirectory
		if !path.IsAbs(workingDirectory) ||
			path.Clean(workingDirectory) != workingDirectory ||
			strings.ContainsRune(workingDirectory, '\x00') {
			return errors.New("sandbox command working directory is invalid")
		}
		totalBytes += len(workingDirectory)
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

func validOptionalSandboxErrorCode(value *string) bool {
	return value == nil || sandboxErrorCodePattern.MatchString(*value)
}

func optionalSandboxStringBytes(value *string) int {
	if value == nil {
		return 0
	}
	return len(*value)
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
