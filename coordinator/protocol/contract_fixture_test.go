package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type protocolFixtureFile struct {
	SchemaVersion int `json:"schema_version"`
	Cases         []struct {
		Name        string `json:"name"`
		MessageType string `json:"message_type"`
		Wire        string `json:"wire"`
		ExactBytes  bool   `json:"exact_bytes"`
	} `json:"cases"`
}

func loadProtocolFixture(t *testing.T, name string) protocolFixtureFile {
	t.Helper()
	path := filepath.Join("..", "..", "tests", "contracts", "protocol", "v1", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var fixture protocolFixtureFile
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	if fixture.SchemaVersion != 1 {
		t.Fatalf("%s schema version = %d, want 1", path, fixture.SchemaVersion)
	}
	return fixture
}

func TestProviderToCoordinatorContractFixturesDecode(t *testing.T) {
	fixture := loadProtocolFixture(t, "provider_to_coordinator.json")
	for _, contract := range fixture.Cases {
		t.Run(contract.Name, func(t *testing.T) {
			var message ProviderMessage
			if err := json.Unmarshal([]byte(contract.Wire), &message); err != nil {
				t.Fatalf("decode: %v\nwire: %s", err, contract.Wire)
			}
			if message.Type != contract.MessageType {
				t.Fatalf("type = %q, want %q", message.Type, contract.MessageType)
			}
			if contract.ExactBytes && contract.MessageType == TypeRegister {
				register, ok := message.Payload.(*RegisterMessage)
				if !ok {
					t.Fatalf("payload = %T, want *RegisterMessage", message.Payload)
				}
				const signed = `{"signature":"sig","attestation":{"z":1,"a":[true,false]}}`
				if string(register.Attestation) != signed {
					t.Fatalf("signed attestation bytes changed\nwant: %s\ngot:  %s", signed, register.Attestation)
				}
			}
		})
	}
}

func TestCoordinatorToProviderContractFixturesDecode(t *testing.T) {
	fixture := loadProtocolFixture(t, "coordinator_to_provider.json")
	for _, contract := range fixture.Cases {
		t.Run(contract.Name, func(t *testing.T) {
			target := coordinatorMessageTarget(t, contract.MessageType)
			if err := json.Unmarshal([]byte(contract.Wire), target); err != nil {
				t.Fatalf("decode: %v\nwire: %s", err, contract.Wire)
			}
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal([]byte(contract.Wire), &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Type != contract.MessageType {
				t.Fatalf("type = %q, want %q", envelope.Type, contract.MessageType)
			}
		})
	}
}

func coordinatorMessageTarget(t *testing.T, messageType string) any {
	t.Helper()
	switch messageType {
	case TypeInferenceRequest:
		return &InferenceRequestMessage{}
	case TypeCancel:
		return &CancelMessage{}
	case TypeAttestationChallenge:
		return &AttestationChallengeMessage{}
	case TypeRuntimeStatus:
		return &RuntimeStatusMessage{}
	case TypeLoadModel:
		return &LoadModelMessage{}
	case TypePrefetchModel:
		return &PrefetchModelMessage{}
	case TypeDesiredModels:
		return &DesiredModelsMessage{}
	case TypeTrustStatus:
		return &TrustStatusMessage{}
	default:
		t.Fatalf("unsupported coordinator contract type %q", messageType)
		return nil
	}
}
