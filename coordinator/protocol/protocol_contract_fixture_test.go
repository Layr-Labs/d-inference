package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

const protocolFixtureSchemaVersion = 1

type protocolFixtureCorpus struct {
	SchemaVersion *uint32               `json:"schema_version"`
	Cases         []protocolFixtureCase `json:"cases"`
}

type protocolFixtureCase struct {
	ID             string          `json:"id"`
	Families       []string        `json:"families"`
	Direction      string          `json:"direction"`
	Message        json.RawMessage `json:"message"`
	NonSharedPaths []string        `json:"non_shared_paths"`
	AbsentPaths    []string        `json:"absent_paths"`
}

func TestSharedProviderMessageContractCorpus(t *testing.T) {
	corpus := loadProtocolFixtureCorpus(t)
	requiredFamilies := map[string]bool{
		"register_heartbeat": false,
		"backend_slot_kv":    false,
		"inference":          false,
		"attestation":        false,
		"model_lifecycle":    false,
		"prefix_cache_v2":    false,
		"tool_constraints":   false,
	}
	seenIDs := make(map[string]bool, len(corpus.Cases))

	for _, fixture := range corpus.Cases {
		fixture := fixture
		t.Run(fixture.ID, func(t *testing.T) {
			if fixture.ID == "" {
				t.Fatal("fixture case ID is empty")
			}
			if seenIDs[fixture.ID] {
				t.Fatalf("duplicate fixture case ID %q", fixture.ID)
			}
			seenIDs[fixture.ID] = true
			if len(fixture.Families) == 0 {
				t.Fatal("fixture case has no family")
			}
			for _, family := range fixture.Families {
				if _, ok := requiredFamilies[family]; !ok {
					t.Fatalf("unknown fixture family %q", family)
				}
				requiredFamilies[family] = true
			}

			encoded := decodeReencodeProtocolFixture(t, fixture)
			assertProtocolFixtureShape(t, fixture, encoded)
		})
	}

	for family, seen := range requiredFamilies {
		if !seen {
			t.Errorf("shared protocol fixture family %q is missing", family)
		}
	}
}

func TestSharedProviderMessageContractSchemaVersionIsRequired(t *testing.T) {
	for _, test := range []struct {
		name string
		data string
	}{
		{name: "missing", data: `{"cases":[]}`},
		{name: "unknown", data: `{"schema_version":2,"cases":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeProtocolFixtureCorpus([]byte(test.data)); err == nil {
				t.Fatal("fixture schema was accepted")
			}
		})
	}
}

func loadProtocolFixtureCorpus(t *testing.T) protocolFixtureCorpus {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "protocol", "v1", "provider_messages.json"))
	if err != nil {
		t.Fatal(err)
	}
	corpus, err := decodeProtocolFixtureCorpus(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return corpus
}

func decodeProtocolFixtureCorpus(encoded []byte) (protocolFixtureCorpus, error) {
	var corpus protocolFixtureCorpus
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		return protocolFixtureCorpus{}, err
	}
	if corpus.SchemaVersion == nil {
		return protocolFixtureCorpus{}, errors.New("protocol fixture schema version is missing")
	}
	if *corpus.SchemaVersion != protocolFixtureSchemaVersion {
		return protocolFixtureCorpus{}, fmt.Errorf("unsupported protocol fixture schema version %d", *corpus.SchemaVersion)
	}
	return corpus, nil
}

func decodeReencodeProtocolFixture(t *testing.T, fixture protocolFixtureCase) []byte {
	t.Helper()
	switch fixture.Direction {
	case "provider_to_coordinator":
		var envelope ProviderMessage
		if err := json.Unmarshal(fixture.Message, &envelope); err != nil {
			t.Fatalf("decode provider message: %v", err)
		}
		encoded, err := json.Marshal(envelope.Payload)
		if err != nil {
			t.Fatalf("re-encode provider message: %v", err)
		}
		return encoded
	case "coordinator_to_provider":
		return decodeReencodeCoordinatorFixture(t, fixture.Message)
	default:
		t.Fatalf("unknown fixture direction %q", fixture.Direction)
		return nil
	}
}

func decodeReencodeCoordinatorFixture(t *testing.T, raw json.RawMessage) []byte {
	t.Helper()
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("decode coordinator envelope: %v", err)
	}

	var message any
	switch envelope.Type {
	case TypeInferenceRequest:
		message = &InferenceRequestMessage{}
	case TypeAttestationChallenge:
		message = &AttestationChallengeMessage{}
	case TypeLoadModel:
		message = &LoadModelMessage{}
	case TypePrefetchModel:
		message = &PrefetchModelMessage{}
	case TypeDesiredModels:
		message = &DesiredModelsMessage{}
	default:
		t.Fatalf("unsupported coordinator fixture type %q", envelope.Type)
	}
	if err := json.Unmarshal(raw, message); err != nil {
		t.Fatalf("decode coordinator message %q: %v", envelope.Type, err)
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatalf("re-encode coordinator message %q: %v", envelope.Type, err)
	}
	return encoded
}

func assertProtocolFixtureShape(t *testing.T, fixture protocolFixtureCase, reencoded []byte) {
	t.Helper()
	original := decodeJSONObject(t, fixture.Message)
	actual := decodeJSONObject(t, reencoded)

	for _, path := range fixture.AbsentPaths {
		if _, ok := protocolJSONPointer(original, path); ok {
			t.Errorf("fixture authority unexpectedly contains absent path %q", path)
		}
		if value, ok := protocolJSONPointer(actual, path); ok {
			t.Errorf("re-encoded message contains absent path %q: %v", path, value)
		}
	}
	for _, path := range fixture.NonSharedPaths {
		removeProtocolJSONPointer(original, path)
		removeProtocolJSONPointer(actual, path)
	}
	if !reflect.DeepEqual(actual, original) {
		want, _ := json.Marshal(original)
		got, _ := json.Marshal(actual)
		t.Fatalf("re-encoded shared shape mismatch\nwant: %s\n got: %s", want, got)
	}
}

func decodeJSONObject(t *testing.T, encoded []byte) map[string]any {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil {
		t.Fatalf("decode JSON object: %v", err)
	}
	return object
}

func protocolJSONPointer(root any, pointer string) (any, bool) {
	current := root
	for _, component := range protocolJSONPointerComponents(pointer) {
		switch value := current.(type) {
		case map[string]any:
			var ok bool
			current, ok = value[component]
			if !ok {
				return nil, false
			}
		case []any:
			index, err := strconv.Atoi(component)
			if err != nil || index < 0 || index >= len(value) {
				return nil, false
			}
			current = value[index]
		default:
			return nil, false
		}
	}
	return current, true
}

func removeProtocolJSONPointer(root map[string]any, pointer string) {
	components := protocolJSONPointerComponents(pointer)
	if len(components) == 0 {
		return
	}
	var current any = root
	for _, component := range components[:len(components)-1] {
		switch value := current.(type) {
		case map[string]any:
			current = value[component]
		case []any:
			index, err := strconv.Atoi(component)
			if err != nil || index < 0 || index >= len(value) {
				return
			}
			current = value[index]
		default:
			return
		}
	}
	last := components[len(components)-1]
	switch value := current.(type) {
	case map[string]any:
		delete(value, last)
	case []any:
		index, err := strconv.Atoi(last)
		if err == nil && index >= 0 && index < len(value) {
			value[index] = nil
		}
	}
}

func protocolJSONPointerComponents(pointer string) []string {
	if pointer == "" {
		return nil
	}
	parts := strings.Split(strings.TrimPrefix(pointer, "/"), "/")
	for index := range parts {
		parts[index] = strings.ReplaceAll(strings.ReplaceAll(parts[index], "~1", "/"), "~0", "~")
	}
	return parts
}
