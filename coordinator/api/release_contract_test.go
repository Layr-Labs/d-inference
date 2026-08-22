package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type releaseFixtureCorpus struct {
	Cases []struct {
		Name               string          `json:"name"`
		CoordinatorEncodes bool            `json:"coordinator_encodes"`
		Response           json.RawMessage `json:"response"`
	} `json:"cases"`
}

func TestLatestReleaseResponseMatchesSharedFixture(t *testing.T) {
	corpus := loadReleaseFixtureCorpus(t)
	seen := make(map[string]bool, len(corpus.Cases))
	encodedCases := 0
	requiredCoordinatorCases := map[string]bool{
		"current_mlx_swift_signed_bundle": false,
		"legacy_vllm_runtime_hashes":      false,
	}

	for _, fixture := range corpus.Cases {
		if fixture.Name == "" {
			t.Fatal("release fixture has an empty case name")
		}
		if seen[fixture.Name] {
			t.Fatalf("duplicate release fixture case %q", fixture.Name)
		}
		seen[fixture.Name] = true
		if !fixture.CoordinatorEncodes {
			continue
		}
		if _, required := requiredCoordinatorCases[fixture.Name]; required {
			requiredCoordinatorCases[fixture.Name] = true
		}
		encodedCases++

		t.Run(fixture.Name, func(t *testing.T) {
			var release store.Release
			if err := json.Unmarshal(fixture.Response, &release); err != nil {
				t.Fatal(err)
			}
			srv, st := testServer(t)
			if err := st.SetRelease(&release); err != nil {
				t.Fatal(err)
			}

			req := httptest.NewRequest(
				http.MethodGet,
				"/v1/releases/latest?platform="+release.Platform,
				nil,
			)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != http.StatusOK {
				t.Fatalf("latest release status = %d, body = %s", w.Code, w.Body.String())
			}

			var actual, expected any
			if err := json.Unmarshal(w.Body.Bytes(), &actual); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(fixture.Response, &expected); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(actual, expected) {
				t.Fatalf("latest release response does not match shared fixture\nactual: %s\nexpected: %s", w.Body.Bytes(), fixture.Response)
			}
		})
	}

	if encodedCases == 0 {
		t.Fatal("release fixture has no coordinator-encoded cases")
	}
	for name, found := range requiredCoordinatorCases {
		if !found {
			t.Errorf("release fixture is missing coordinator-encoded case %q", name)
		}
	}
}

func TestReleaseFixtureSchemaVersionFailsClosed(t *testing.T) {
	for _, test := range []struct {
		name string
		data string
	}{
		{name: "missing", data: `{"cases":[]}`},
		{name: "unsupported", data: `{"schema_version":2,"cases":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeReleaseFixtureCorpus([]byte(test.data)); err == nil {
				t.Fatal("release fixture schema was accepted")
			}
		})
	}
}

func loadReleaseFixtureCorpus(t *testing.T) releaseFixtureCorpus {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "release", "v1", "latest_response.json"))
	if err != nil {
		t.Fatal(err)
	}
	corpus, err := decodeReleaseFixtureCorpus(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return corpus
}

func decodeReleaseFixtureCorpus(encoded []byte) (releaseFixtureCorpus, error) {
	var metadata struct {
		SchemaVersion *uint32 `json:"schema_version"`
	}
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		return releaseFixtureCorpus{}, err
	}
	if metadata.SchemaVersion == nil {
		return releaseFixtureCorpus{}, errors.New("release fixture schema version is missing")
	}
	if *metadata.SchemaVersion != 1 {
		return releaseFixtureCorpus{}, fmt.Errorf("unsupported release fixture schema version %d", *metadata.SchemaVersion)
	}

	var corpus releaseFixtureCorpus
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		return releaseFixtureCorpus{}, err
	}
	return corpus, nil
}
