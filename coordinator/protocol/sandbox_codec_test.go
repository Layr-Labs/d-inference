package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

const (
	testSandboxHostID    = "00000000-0000-0000-0000-000000000001"
	testSandboxEpoch     = "00000000-0000-0000-0000-000000000002"
	testSandboxID        = "00000000-0000-0000-0000-000000000003"
	testSandboxOperation = "00000000-0000-0000-0000-000000000004"
	testSandboxCommand   = "00000000-0000-0000-0000-000000000005"
	testSandboxExpiry    = "2026-08-24T23:15:00Z"
)

func TestDecodeSandboxHostRegister(t *testing.T) {
	frame := marshalSandboxFrame(t, SandboxEnvelope[SandboxHostRegisterPayload]{
		Type:            SandboxTypeHostRegister,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        1,
		Payload: SandboxHostRegisterPayload{
			Capabilities: SandboxHostCapabilities{
				DaemonVersion:       "0.1.0",
				OperatingSystem:     "macos",
				Architecture:        "arm64",
				MachineModel:        "Mac16,1",
				ChipName:            "Apple M4 Pro",
				CPUCount:            12,
				MemoryBytes:         48 * sandboxGibibyte,
				MaximumSandboxes:    2,
				WorkspaceSizesBytes: []uint64{sandboxWorkspace25GiB, sandboxWorkspace50GiB},
				BaseImageIDs:        []string{"macos-tahoe-v1"},
				SupportsGPU:         true,
			},
		},
	})

	decoded, err := DecodeSandboxHostMessage(frame)
	if err != nil {
		t.Fatalf("decode host register: %v", err)
	}
	if decoded.Header.Type != SandboxTypeHostRegister ||
		decoded.Header.Sequence != 1 {
		t.Fatalf("unexpected header: %+v", decoded.Header)
	}
	payload, ok := decoded.Payload.(*SandboxHostRegisterPayload)
	if !ok {
		t.Fatalf("unexpected payload type %T", decoded.Payload)
	}
	if payload.Capabilities.ChipName != "Apple M4 Pro" ||
		payload.Capabilities.MaximumSandboxes != 2 {
		t.Fatalf("unexpected capabilities: %+v", payload.Capabilities)
	}
	if _, err := DecodeSandboxCoordinatorMessage(frame); err == nil {
		t.Fatal("host register decoded in coordinator-to-host direction")
	}
}

func TestDecodeSandboxCoordinatorCommand(t *testing.T) {
	frame := marshalSandboxFrame(t, validSandboxCommandEnvelope())
	decoded, err := DecodeSandboxCoordinatorMessage(frame)
	if err != nil {
		t.Fatalf("decode command: %v", err)
	}
	payload, ok := decoded.Payload.(*SandboxCommandPayload)
	if !ok {
		t.Fatalf("unexpected payload type %T", decoded.Payload)
	}
	if payload.Arguments[0] != "/usr/bin/printf" ||
		payload.TimeoutSeconds != 900 ||
		payload.Scope.FencingToken != 7 {
		t.Fatalf("unexpected command: %+v", payload)
	}
}

func TestSandboxCommandGoldenJSON(t *testing.T) {
	encoded := string(marshalSandboxFrame(t, validSandboxCommandEnvelope()))
	const expected = `{"type":"sandbox_command","protocol_version":1,` +
		`"host_id":"00000000-0000-0000-0000-000000000001",` +
		`"connection_epoch":"00000000-0000-0000-0000-000000000002",` +
		`"sequence":9,"payload":{` +
		`"command_id":"00000000-0000-0000-0000-000000000005",` +
		`"idempotency_key":"00000000-0000-0000-0000-000000000006","scope":{` +
		`"sandbox_id":"00000000-0000-0000-0000-000000000003",` +
		`"generation":3,"fencing_token":7},` +
		`"arguments":["/usr/bin/printf","hello"],` +
		`"working_directory":"/workspace","timeout_seconds":900}}`
	if encoded != expected {
		t.Fatalf("sandbox command JSON mismatch\n got: %s\nwant: %s", encoded, expected)
	}
}

func TestSandboxCodecRejectsAmbiguousOrInvalidFrames(t *testing.T) {
	valid := string(marshalSandboxFrame(t, validSandboxCommandEnvelope()))
	tests := map[string]string{
		"duplicate envelope key": strings.Replace(
			valid,
			`"sequence":9`,
			`"sequence":9,"sequence":10`,
			1,
		),
		"case folded envelope key": strings.Replace(
			valid,
			`"sequence":9`,
			`"Sequence":9`,
			1,
		),
		"case folded duplicate envelope key": strings.Replace(
			valid,
			`"sequence":9`,
			`"sequence":9,"\u0053equence":10`,
			1,
		),
		"duplicate payload key": strings.Replace(
			valid,
			`"timeout_seconds":900`,
			`"timeout_seconds":900,"timeout_seconds":1`,
			1,
		),
		"unknown envelope key": strings.Replace(
			valid,
			`"sequence":9`,
			`"sequence":9,"auth_token":"forbidden"`,
			1,
		),
		"unknown payload key": strings.Replace(
			valid,
			`"timeout_seconds":900`,
			`"timeout_seconds":900,"shell":true`,
			1,
		),
		"zero sequence": strings.Replace(valid, `"sequence":9`, `"sequence":0`, 1),
		"wrong version": strings.Replace(
			valid,
			`"protocol_version":1`,
			`"protocol_version":2`,
			1,
		),
		"relative working directory": strings.Replace(
			valid,
			`"working_directory":"/workspace"`,
			`"working_directory":"workspace"`,
			1,
		),
		"empty working directory": strings.Replace(
			valid,
			`"working_directory":"/workspace"`,
			`"working_directory":""`,
			1,
		),
		"null optional environment": strings.Replace(
			valid,
			`"working_directory":"/workspace"`,
			`"environment":null,"working_directory":"/workspace"`,
			1,
		),
		"timeout exceeds lease contract": strings.Replace(
			valid,
			`"timeout_seconds":900`,
			`"timeout_seconds":901`,
			1,
		),
		"non-UUID idempotency key": strings.Replace(
			valid,
			`"idempotency_key":"00000000-0000-0000-0000-000000000006"`,
			`"idempotency_key":"command-attempt-1"`,
			1,
		),
		"trailing JSON": valid + `{}`,
		"noncanonical host UUID": strings.Replace(
			valid,
			testSandboxHostID,
			"00000000000000000000000000000001",
			1,
		),
	}
	for name, frame := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeSandboxCoordinatorMessage([]byte(frame)); err == nil {
				t.Fatal("invalid frame was accepted")
			}
		})
	}
}

func TestSandboxCodecPreservesCaseSensitiveEnvironment(t *testing.T) {
	frame := validSandboxCommandEnvelope()
	frame.Payload.Environment = map[string]string{
		"FOO": "upper",
		"foo": "lower",
	}
	decoded, err := DecodeSandboxCoordinatorMessage(marshalSandboxFrame(t, frame))
	if err != nil {
		t.Fatalf("case-sensitive environment rejected: %v", err)
	}
	payload := decoded.Payload.(*SandboxCommandPayload)
	if payload.Environment["FOO"] != "upper" ||
		payload.Environment["foo"] != "lower" {
		t.Fatalf("environment changed: %#v", payload.Environment)
	}
}

func TestSandboxCodecNormalizesAndRejectsEmptyEnvironment(t *testing.T) {
	frame := validSandboxCommandEnvelope()
	frame.Payload.Environment = map[string]string{}
	encoded := string(marshalSandboxFrame(t, frame))
	if strings.Contains(encoded, `"environment"`) {
		t.Fatalf("empty environment was serialized: %s", encoded)
	}
	withEmptyEnvironment := strings.Replace(
		encoded,
		`"working_directory":"/workspace"`,
		`"environment":{},"working_directory":"/workspace"`,
		1,
	)
	if _, err := DecodeSandboxCoordinatorMessage(
		[]byte(withEmptyEnvironment),
	); err == nil {
		t.Fatal("explicit empty environment was accepted")
	}
}

func TestSandboxCodecRequiresZeroValuedAndCollectionFields(t *testing.T) {
	prepare := SandboxEnvelope[SandboxPreparePayload]{
		Type:            SandboxTypePrepare,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        11,
		Payload: SandboxPreparePayload{
			OperationID: testSandboxOperation,
			Scope: SandboxScope{
				SandboxID:    testSandboxID,
				Generation:   3,
				FencingToken: 7,
			},
			Resources: SandboxResources{
				CPUCount:              4,
				MemoryBytes:           8 * sandboxGibibyte,
				WorkspaceBytes:        sandboxWorkspace25GiB,
				CommandTimeoutSeconds: 900,
				GPU:                   false,
			},
			BaseImageID:    "macos-tahoe-v1",
			LeaseExpiresAt: testSandboxExpiry,
		},
	}
	validPrepare := string(marshalSandboxFrame(t, prepare))
	for name, frame := range map[string]string{
		"missing gpu": strings.Replace(validPrepare, `,"gpu":false`, "", 1),
		"null gpu": strings.Replace(
			validPrepare,
			`"gpu":false`,
			`"gpu":null`,
			1,
		),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeSandboxCoordinatorMessage([]byte(frame)); err == nil {
				t.Fatal("prepare with absent required field was accepted")
			}
		})
	}

	heartbeat := SandboxEnvelope[SandboxHostHeartbeatPayload]{
		Type:            SandboxTypeHostHeartbeat,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        12,
		Payload: SandboxHostHeartbeatPayload{
			Mode:             "sandbox_dedicated",
			AvailableCPU:     12,
			AvailableMemory:  48 * sandboxGibibyte,
			NextFencingToken: 1,
			Leases:           []SandboxHostLeaseObservation{},
		},
	}
	validHeartbeat := string(marshalSandboxFrame(t, heartbeat))
	for name, frame := range map[string]string{
		"missing leases": strings.Replace(validHeartbeat, `,"leases":[]`, "", 1),
		"null leases": strings.Replace(
			validHeartbeat,
			`"leases":[]`,
			`"leases":null`,
			1,
		),
		"missing next fencing token": strings.Replace(
			validHeartbeat,
			`,"next_fencing_token":1`,
			"",
			1,
		),
		"zero next fencing token": strings.Replace(
			validHeartbeat,
			`"next_fencing_token":1`,
			`"next_fencing_token":0`,
			1,
		),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeSandboxHostMessage([]byte(frame)); err == nil {
				t.Fatal("heartbeat with absent leases was accepted")
			}
		})
	}
}

func TestSandboxCodecRejectsInvalidUTF8(t *testing.T) {
	frame := marshalSandboxFrame(t, validSandboxCommandEnvelope())
	index := strings.Index(string(frame), "hello")
	if index < 0 {
		t.Fatal("fixture does not contain command argument")
	}
	frame[index] = 0xff
	if _, err := DecodeSandboxCoordinatorMessage(frame); err == nil {
		t.Fatal("frame with invalid UTF-8 was accepted")
	}
}

func TestSandboxCodecRejectsUnpairedSurrogateAndExcessiveDepth(t *testing.T) {
	valid := string(marshalSandboxFrame(t, validSandboxCommandEnvelope()))
	unpaired := strings.Replace(valid, `"hello"`, `"\ud800"`, 1)
	if _, err := DecodeSandboxCoordinatorMessage([]byte(unpaired)); err == nil {
		t.Fatal("unpaired Unicode surrogate was accepted")
	}
	deep := []byte(strings.Repeat("[", 66) + "0" + strings.Repeat("]", 66))
	if _, err := DecodeSandboxCoordinatorMessage(deep); err == nil {
		t.Fatal("excessively nested JSON was accepted")
	}
}

func TestSandboxHostFailureRejectsExplicitEmptyOptionalID(t *testing.T) {
	frame := `{"type":"sandbox_host_failure","protocol_version":1,` +
		`"host_id":"` + testSandboxHostID + `",` +
		`"connection_epoch":"` + testSandboxEpoch + `","sequence":1,` +
		`"payload":{"operation_id":"","command_id":"` + testSandboxCommand +
		`","error_code":"host.failure"}}`
	if _, err := DecodeSandboxHostMessage([]byte(frame)); err == nil {
		t.Fatal("explicit empty optional operation ID was accepted")
	}
}

func TestSandboxCodecRejectsInvalidHostState(t *testing.T) {
	exitCode := int32(0)
	standardOutput := "hello"
	valid := SandboxEnvelope[SandboxCommandStatePayload]{
		Type:            SandboxTypeCommandState,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        10,
		Payload: SandboxCommandStatePayload{
			CommandID: testSandboxCommand,
			Scope: SandboxScope{
				SandboxID:    testSandboxID,
				Generation:   3,
				FencingToken: 7,
			},
			State:          SandboxCommandSucceeded,
			ExitCode:       &exitCode,
			StandardOutput: &standardOutput,
		},
	}
	if _, err := DecodeSandboxHostMessage(marshalSandboxFrame(t, valid)); err != nil {
		t.Fatalf("valid terminal command state rejected: %v", err)
	}
	encoded := string(marshalSandboxFrame(t, valid))
	if !strings.Contains(encoded, `"output_truncated":false`) {
		t.Fatalf("required output_truncated field was omitted: %s", encoded)
	}
	withoutTruncation := strings.Replace(
		encoded,
		`,"output_truncated":false`,
		"",
		1,
	)
	if _, err := DecodeSandboxHostMessage([]byte(withoutTruncation)); err == nil {
		t.Fatal("command state without output_truncated was accepted")
	}

	valid.Payload.ExitCode = nil
	if _, err := DecodeSandboxHostMessage(marshalSandboxFrame(t, valid)); err == nil {
		t.Fatal("terminal command without exit code was accepted")
	}

	valid.Payload.State = "complete"
	if _, err := DecodeSandboxHostMessage(marshalSandboxFrame(t, valid)); err == nil {
		t.Fatal("unknown command state was accepted")
	}
}

func TestSandboxCodecRejectsOversizedFrame(t *testing.T) {
	frame := []byte(`{"padding":"` + strings.Repeat("x", maxSandboxFrameBytes) + `"}`)
	if _, err := DecodeSandboxHostMessage(frame); err == nil {
		t.Fatal("oversized frame was accepted")
	}
}

func TestSandboxCodecAppliesBudgetToEncodedCommandOutput(t *testing.T) {
	exitCode := int32(0)
	commandState := SandboxEnvelope[SandboxCommandStatePayload]{
		Type:            SandboxTypeCommandState,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        11,
		Payload: SandboxCommandStatePayload{
			CommandID: testSandboxCommand,
			Scope: SandboxScope{
				SandboxID:    testSandboxID,
				Generation:   3,
				FencingToken: 7,
			},
			State:    SandboxCommandSucceeded,
			ExitCode: &exitCode,
		},
	}
	withinBudget := strings.Repeat("\x00", 100_000)
	commandState.Payload.StandardOutput = &withinBudget
	commandState.Payload.StandardError = &withinBudget
	encoded := marshalSandboxFrame(t, commandState)
	if len(encoded) > maxSandboxFrameBytes {
		t.Fatalf("boundary fixture exceeds frame budget: %d", len(encoded))
	}
	if _, err := DecodeSandboxHostMessage(encoded); err != nil {
		t.Fatalf("encoded command output within frame budget rejected: %v", err)
	}

	overBudget := strings.Repeat("\x00", 400_000)
	commandState.Payload.StandardOutput = &overBudget
	commandState.Payload.StandardError = &overBudget
	encoded = marshalSandboxFrame(t, commandState)
	if len(encoded) <= maxSandboxFrameBytes {
		t.Fatalf("pathological output fixture did not exceed frame budget: %d", len(encoded))
	}
	if _, err := DecodeSandboxHostMessage(encoded); err == nil {
		t.Fatal("encoded command output beyond frame budget was accepted")
	}
}

func validSandboxCommandEnvelope() SandboxEnvelope[SandboxCommandPayload] {
	workingDirectory := "/workspace"
	return SandboxEnvelope[SandboxCommandPayload]{
		Type:            SandboxTypeCommand,
		ProtocolVersion: SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxEpoch,
		Sequence:        9,
		Payload: SandboxCommandPayload{
			CommandID:      testSandboxCommand,
			IdempotencyKey: "00000000-0000-0000-0000-000000000006",
			Scope: SandboxScope{
				SandboxID:    testSandboxID,
				Generation:   3,
				FencingToken: 7,
			},
			Arguments:        []string{"/usr/bin/printf", "hello"},
			WorkingDirectory: &workingDirectory,
			TimeoutSeconds:   900,
		},
	}
}

func marshalSandboxFrame(t *testing.T, frame any) []byte {
	t.Helper()
	encoded, err := json.Marshal(frame)
	if err != nil {
		t.Fatalf("marshal sandbox frame: %v", err)
	}
	return encoded
}
