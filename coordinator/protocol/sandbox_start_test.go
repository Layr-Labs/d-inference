package protocol

import (
	"encoding/json"
	"testing"
)

func TestSandboxStartWireContract(t *testing.T) {
	payload := SandboxStartPayload{OperationID: testSandboxOperation, Scope: SandboxScope{SandboxID: testSandboxID, Generation: 3, FencingToken: 7},
		RequestedFencingToken: 8, LeaseExpiresAt: testSandboxExpiry}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	const golden = `{"operation_id":"00000000-0000-0000-0000-000000000004","scope":{"sandbox_id":"00000000-0000-0000-0000-000000000003","generation":3,"fencing_token":7},"requested_fencing_token":8,"lease_expires_at":"2026-08-24T23:15:00Z"}`
	if string(encoded) != golden {
		t.Fatalf("start wire mismatch: %s", encoded)
	}
	envelope := SandboxEnvelope[SandboxStartPayload]{Type: SandboxTypeStart, ProtocolVersion: SandboxProtocolVersion, HostID: testSandboxHostID, ConnectionEpoch: testSandboxEpoch, Sequence: 2, Payload: payload}
	frame := marshalSandboxFrame(t, envelope)
	if _, err := DecodeSandboxCoordinatorMessage(frame); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeSandboxHostMessage(frame); err == nil {
		t.Fatal("start accepted in host-to-coordinator direction")
	}
	for _, invalid := range []uint64{0, 7, sandboxMaximumFence + 1} {
		envelope.Payload.RequestedFencingToken = invalid
		if _, err := DecodeSandboxCoordinatorMessage(marshalSandboxFrame(t, envelope)); err == nil {
			t.Fatalf("invalid start fence %d accepted", invalid)
		}
	}
}
