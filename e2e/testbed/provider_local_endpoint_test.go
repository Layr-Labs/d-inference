package testbed

import (
	"reflect"
	"strings"
	"testing"
)

func TestLocalEndpointArguments(t *testing.T) {
	args, err := localEndpointArguments(0)
	if err != nil || len(args) != 0 {
		t.Fatalf("zero must preserve launch: %v, %v", args, err)
	}
	args, err = localEndpointArguments(18181)
	want := []string{"--local-endpoint", "--port", "18181", "--bind", "127.0.0.1"}
	if err != nil || !reflect.DeepEqual(args, want) {
		t.Fatalf("arguments = %v, %v, want %v", args, err, want)
	}
	for _, port := range []int{-1, 1, 1023, 65536} {
		if _, err := localEndpointArguments(port); err == nil {
			t.Fatalf("invalid port %d accepted", port)
		}
	}
}

func TestLocalEndpointPreservesCoordinatorAndAuth(t *testing.T) {
	root := t.TempDir()
	spec, err := buildProviderStartSpec("http://127.0.0.1:54321", root,
		ProviderConfig{ModelID: "org/model", LocalEndpointPort: 18181, AuthTokenPath: root + "/auth.json"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(spec.Arguments, " ")
	if !strings.Contains(joined, "--coordinator-url ws://127.0.0.1:54321/ws/provider") ||
		!strings.Contains(joined, "--local-endpoint --port 18181 --bind 127.0.0.1") ||
		strings.Contains(joined, "--no-auth") {
		t.Fatalf("unexpected launch %q", joined)
	}
	if spec.Environment["DARKBLOOM_LOCAL_DIR"] != root+"/local" ||
		spec.Environment["DARKBLOOM_AUTH_TOKEN_PATH"] != root+"/auth.json" {
		t.Fatal("test-local credential isolation changed")
	}
}

func TestLocalEndpointRejectsAmbiguousProviderOwnership(t *testing.T) {
	for _, test := range []struct {
		port, providers int
		owned, valid    bool
	}{
		{0, 2, true, true}, {18181, 1, false, true},
		{18181, 0, false, false}, {18181, 2, false, false},
		{18181, 1, true, false}, {-1, 1, false, false},
	} {
		if valid := validateLocalEndpointSelection(test.port, test.providers, test.owned) == nil; valid != test.valid {
			t.Fatalf("selection %+v validity = %v", test, valid)
		}
	}
}
