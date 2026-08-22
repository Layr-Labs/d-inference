package protocol

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type telemetryFixtureCorpus struct {
	SchemaVersion *uint32 `json:"schema_version"`
	Vocabularies  struct {
		Sources    map[string]bool `json:"sources"`
		Severities map[string]bool `json:"severities"`
		Kinds      map[string]bool `json:"kinds"`
	} `json:"vocabularies"`
	RequiredEventFields map[string]bool `json:"required_event_fields"`
	OptionalEventFields map[string]bool `json:"optional_event_fields"`
	Cases               []struct {
		Name        string          `json:"name"`
		Event       json.RawMessage `json:"event"`
		OmittedKeys []string        `json:"omitted_keys"`
	} `json:"cases"`
}

func TestTelemetryJSONSymmetry(t *testing.T) {
	corpus := loadTelemetryFixture(t)
	if len(corpus.Cases) == 0 {
		t.Fatal("telemetry fixture has no named cases")
	}

	actualRequiredFields, actualOptionalFields := telemetryEventFieldSets()
	assertTelemetryFixtureSet(t, "required event fields", actualRequiredFields, corpus.RequiredEventFields)
	assertTelemetryFixtureSet(t, "optional event fields", actualOptionalFields, corpus.OptionalEventFields)

	declaredFields := make(map[string]bool, len(corpus.RequiredEventFields)+len(corpus.OptionalEventFields))
	for name, enabled := range corpus.RequiredEventFields {
		if !enabled {
			t.Fatalf("required event field %q is disabled", name)
		}
		declaredFields[name] = true
	}
	for name, enabled := range corpus.OptionalEventFields {
		if !enabled {
			t.Fatalf("optional event field %q is disabled", name)
		}
		if declaredFields[name] {
			t.Fatalf("event field %q is both required and optional", name)
		}
		declaredFields[name] = true
	}

	seenNames := make(map[string]bool, len(corpus.Cases))
	sawOmissionCase := false
	sawAllFieldsCase := false
	for _, fixture := range corpus.Cases {
		fixture := fixture
		if fixture.Name == "" || seenNames[fixture.Name] {
			t.Fatalf("invalid or duplicate telemetry fixture name %q", fixture.Name)
		}
		seenNames[fixture.Name] = true
		t.Run(fixture.Name, func(t *testing.T) {
			var event TelemetryEvent
			if err := json.Unmarshal(fixture.Event, &event); err != nil {
				t.Fatalf("decode fixture event: %v", err)
			}
			encoded, err := json.Marshal(event)
			if err != nil {
				t.Fatalf("encode telemetry event: %v", err)
			}

			var expected, actual map[string]any
			if err := json.Unmarshal(fixture.Event, &expected); err != nil {
				t.Fatalf("decode expected JSON: %v", err)
			}
			if err := json.Unmarshal(encoded, &actual); err != nil {
				t.Fatalf("decode encoded JSON: %v", err)
			}
			if !reflect.DeepEqual(actual, expected) {
				t.Fatalf("wire JSON mismatch:\n got: %s\nwant: %s", encoded, fixture.Event)
			}

			for field := range corpus.RequiredEventFields {
				if _, ok := actual[field]; !ok {
					t.Errorf("required field %q is missing", field)
				}
			}
			for field := range actual {
				if !declaredFields[field] {
					t.Errorf("undeclared wire field %q", field)
				}
			}
			omittedFields := make(map[string]bool, len(fixture.OmittedKeys))
			for _, field := range fixture.OmittedKeys {
				if !corpus.OptionalEventFields[field] {
					t.Fatalf("omitted field %q is not declared optional", field)
				}
				if omittedFields[field] {
					t.Fatalf("omitted field %q is duplicated", field)
				}
				omittedFields[field] = true
				if _, ok := actual[field]; ok {
					t.Errorf("optional field %q should be omitted", field)
				}
			}
			for field := range corpus.OptionalEventFields {
				_, present := actual[field]
				if !present != omittedFields[field] {
					t.Errorf("optional field %q omission is not declared by the fixture case", field)
				}
			}

			for _, vocabulary := range []struct {
				field  string
				values map[string]bool
			}{
				{field: "source", values: corpus.Vocabularies.Sources},
				{field: "severity", values: corpus.Vocabularies.Severities},
				{field: "kind", values: corpus.Vocabularies.Kinds},
			} {
				value, ok := actual[vocabulary.field].(string)
				if !ok || !vocabulary.values[value] {
					t.Errorf("%s value %q is outside the fixture vocabulary", vocabulary.field, value)
				}
			}
		})

		if len(fixture.OmittedKeys) > 0 {
			sawOmissionCase = true
		}
		var eventFields map[string]any
		if err := json.Unmarshal(fixture.Event, &eventFields); err != nil {
			t.Fatal(err)
		}
		hasAllFields := true
		for field := range declaredFields {
			if _, ok := eventFields[field]; !ok {
				hasAllFields = false
				break
			}
		}
		sawAllFieldsCase = sawAllFieldsCase || hasAllFields
	}
	if !sawOmissionCase || !sawAllFieldsCase {
		t.Fatal("telemetry fixture must cover optional omission and all declared event fields")
	}
}

func TestTelemetryVocabulariesMatch(t *testing.T) {
	corpus := loadTelemetryFixture(t)

	sources := make(map[string]bool, len(KnownSources()))
	for value := range KnownSources() {
		sources[string(value)] = true
	}
	assertTelemetryFixtureSet(t, "source vocabulary", sources, corpus.Vocabularies.Sources)

	severities := make(map[string]bool, len(KnownSeverities()))
	for value := range KnownSeverities() {
		severities[string(value)] = true
	}
	assertTelemetryFixtureSet(t, "severity vocabulary", severities, corpus.Vocabularies.Severities)

	kinds := make(map[string]bool, len(KnownKinds()))
	for value := range KnownKinds() {
		kinds[string(value)] = true
	}
	assertTelemetryFixtureSet(t, "kind vocabulary", kinds, corpus.Vocabularies.Kinds)
}

func TestTelemetryFixtureSchemaVersionIsRequired(t *testing.T) {
	for _, test := range []struct {
		name    string
		encoded string
	}{
		{name: "missing", encoded: `{"cases":[]}`},
		{name: "unsupported", encoded: `{"schema_version":2,"cases":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			var corpus telemetryFixtureCorpus
			if err := decodeTelemetryFixture([]byte(test.encoded), &corpus); err == nil {
				t.Fatal("fixture schema was accepted")
			}
		})
	}
}

func loadTelemetryFixture(t *testing.T) telemetryFixtureCorpus {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "telemetry", "v1", "events.json"))
	if err != nil {
		t.Fatal(err)
	}
	var corpus telemetryFixtureCorpus
	if err := decodeTelemetryFixture(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	return corpus
}

func decodeTelemetryFixture(encoded []byte, output *telemetryFixtureCorpus) error {
	var metadata struct {
		SchemaVersion *uint32 `json:"schema_version"`
	}
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		return err
	}
	if metadata.SchemaVersion == nil {
		return errors.New("fixture schema version is missing")
	}
	if *metadata.SchemaVersion != 1 {
		return fmt.Errorf("unsupported fixture schema version %d", *metadata.SchemaVersion)
	}
	return json.Unmarshal(encoded, output)
}

func telemetryEventFieldSets() (map[string]bool, map[string]bool) {
	eventType := reflect.TypeOf(TelemetryEvent{})
	required := make(map[string]bool, eventType.NumField())
	optional := make(map[string]bool, eventType.NumField())
	for index := range eventType.NumField() {
		tag := strings.Split(eventType.Field(index).Tag.Get("json"), ",")
		if len(tag) == 0 || tag[0] == "" || tag[0] == "-" {
			continue
		}
		fields := required
		for _, option := range tag[1:] {
			if option == "omitempty" {
				fields = optional
				break
			}
		}
		fields[tag[0]] = true
	}
	return required, optional
}

func assertTelemetryFixtureSet(t *testing.T, name string, actual, expected map[string]bool) {
	t.Helper()
	if !reflect.DeepEqual(actual, expected) {
		t.Errorf("%s mismatch: got %v, want %v", name, actual, expected)
	}
}
