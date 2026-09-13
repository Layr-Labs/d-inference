package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const testDatabaseURL = "postgres://fixture:private-password@127.0.0.1:15432/darkbloom_sandbox_acceptance_test?sslmode=disable"

func TestFixtureRejectsAmbiguousOrProductionDatabaseTargets(t *testing.T) {
	for _, valid := range []string{testDatabaseURL, strings.Replace(testDatabaseURL, "127.0.0.1", "[::1]", 1)} {
		if err := validateDatabaseURL(valid); err != nil {
			t.Fatal(err)
		}
	}
	for _, invalid := range []string{
		strings.Replace(testDatabaseURL, "127.0.0.1", "localhost", 1), strings.Replace(testDatabaseURL, "127.0.0.1", "203.0.113.1", 1),
		strings.Replace(testDatabaseURL, "darkbloom_sandbox_acceptance_test", "production", 1),
		strings.Replace(testDatabaseURL, ":private-password", "", 1), testDatabaseURL + "&host=production", testDatabaseURL + "&service=prod", testDatabaseURL + "&sslmode=require",
	} {
		if err := validateDatabaseURL(invalid); err == nil || strings.Contains(err.Error(), "private-password") {
			t.Fatalf("invalid/secret-exposing validation: %v", err)
		}
	}
}

func TestFixtureUsesRealConsumerAndDedicatedHostAuthentication(t *testing.T) {
	backend := store.NewMemory(store.Config{})
	directory, plan, consumer, environment := seedMemoryFixture(t, backend)
	token, err := readPrivate(filepath.Join(directory, "host-token"), 512)
	if err != nil {
		t.Fatal(err)
	}
	authenticator, err := sandboxhost.NewAuthenticator(sandboxhost.AuthConfig{TokenSHA256JSON: environment["EIGENINFERENCE_SANDBOX_HOST_TOKEN_SHA256_JSON"]})
	if err != nil || !authenticator.Authenticate(plan.HostID, strings.TrimSpace(string(token))) || authenticator.Authenticate(plan.HostID, "wrong-token") {
		t.Fatalf("host credentials are not real authenticator-compatible: %v", err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := api.NewServer(registry.New(logger), store.NewCached(backend, store.CacheConfig{}), api.ServerConfig{
		SandboxService:  api.SandboxServiceConfig{Enabled: true, AdmissionEnabled: true, AllowedAccountIDs: []string{plan.AccountID}},
		SandboxHostAuth: sandboxhost.AuthConfig{TokenSHA256JSON: environment["EIGENINFERENCE_SANDBOX_HOST_TOKEN_SHA256_JSON"]},
	}, logger)
	defer server.Close()
	for _, test := range []struct {
		key    string
		status int
	}{{consumer["DARKBLOOM_API_KEY"], http.StatusOK}, {"wrong-key", http.StatusUnauthorized}, {"", http.StatusUnauthorized}} {
		request := httptest.NewRequest(http.MethodGet, "/v1/sandboxes", nil)
		if test.key != "" {
			request.Header.Set("Authorization", "Bearer "+test.key)
		}
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, request)
		if response.Code != test.status {
			t.Fatalf("real sandbox auth status=%d want=%d", response.Code, test.status)
		}
	}
	user, err := backend.GetUserByAccountID(plan.AccountID)
	if err != nil || user.Role != "" {
		t.Fatalf("fixture is not an ordinary consumer: %+v %v", user, err)
	}
}

func TestFixtureLaunchCannotInheritSecretsOrBroadenBind(t *testing.T) {
	directory, plan, _, _ := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "production-url")
	t.Setenv("DD_API_KEY", "production-dd-secret")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "production-cloud-secret")
	_, args, environment, err := launchCommand(directory, plan, "run-coordinator", nil)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(environment, "\n")
	if len(args) != 0 || !strings.Contains(joined, "EIGENINFERENCE_BIND_HOST=127.0.0.1") || strings.Contains(joined, "production-") || strings.Contains(joined, "ADMIN_KEY=") {
		t.Fatalf("unsafe launch environment: %v", err)
	}
	if _, _, _, err := launchCommand(directory, plan, "run-client", []string{"--api-url", "https://api.darkbloom.dev", "list"}); err == nil {
		t.Fatal("global client origin override accepted")
	}
	changed := plan
	changed.APIURL = "http://0.0.0.0:18080"
	if _, _, _, err := launchCommand(directory, changed, "run-coordinator", nil); err == nil {
		t.Fatal("nonloopback origin accepted")
	}
	if err := run([]string{"run-coordinator", "--directory", directory}); err == nil {
		t.Fatal("service launch lacked explicit confirmation")
	}
}

func TestPrivateFixtureFilesRejectLinksPublicModesAndOverwrite(t *testing.T) {
	root := t.TempDir()
	name := filepath.Join(root, "secret")
	if err := writePrivate(name, []byte("private")); err != nil {
		t.Fatal(err)
	}
	if err := writePrivate(name, []byte("replacement")); err == nil {
		t.Fatal("overwrote credential")
	}
	link := filepath.Join(root, "alias")
	if err := os.Symlink(name, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivate(link, 100); err == nil {
		t.Fatal("credential symlink accepted")
	}
	if err := os.Chmod(name, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivate(name, 100); err == nil {
		t.Fatal("public-readable credential accepted")
	}
}

func TestAcceptanceLaunchUsesSeededConfigWithoutPrintingKey(t *testing.T) {
	directory, plan, consumer, _ := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	harness := filepath.Join(directory, "test-sandbox-live.py")
	if err := os.WriteFile(harness, []byte("# test fixture only\n"), 0600); err != nil {
		t.Fatal(err)
	}
	program, args, environment, err := acceptanceCommand(directory, plan, plan.Client, harness, filepath.Join(directory, "evidence"), true)
	if err != nil {
		t.Fatal(err)
	}
	if program != plan.Client || !strings.Contains(strings.Join(args, " "), "--workspace-exhaustion") || strings.Contains(strings.Join(args, " "), consumer["DARKBLOOM_API_KEY"]) {
		t.Fatal("acceptance arguments lost opt-in or exposed credentials")
	}
	if !strings.Contains(strings.Join(environment, "\n"), "DARKBLOOM_API_KEY="+consumer["DARKBLOOM_API_KEY"]) {
		t.Fatal("acceptance did not receive private consumer identity")
	}
	configFile := filepath.Join(directory, "consumer-config.json")
	if err := os.WriteFile(configFile, []byte(`{"environment":"production","api_url":"https://api.darkbloom.dev"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := acceptanceCommand(directory, plan, plan.Client, harness, filepath.Join(directory, "evidence"), false); err == nil {
		t.Fatal("changed acceptance target accepted")
	}
}

func TestCoordinatorLaunchRejectsExtraEnvironmentSettings(t *testing.T) {
	directory, plan, _, environment := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	environment["DD_API_KEY"] = "must-not-reach-child"
	data, _ := json.Marshal(environment)
	if err := os.WriteFile(filepath.Join(directory, "coordinator-env.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := launchCommand(directory, plan, "run-coordinator", nil); err == nil {
		t.Fatal("extra credential environment accepted")
	}
}

func seedMemoryFixture(t *testing.T, backend seedStore) (string, fixturePlan, map[string]string, map[string]string) {
	t.Helper()
	directory := t.TempDir()
	program := filepath.Join(directory, "test-program")
	if err := os.WriteFile(program, []byte("fixture test executable placeholder"), 0700); err != nil {
		t.Fatal(err)
	}
	options := seedOptions{Directory: directory, DatabaseFile: filepath.Join(directory, "database-url"), BaseImage: "macos-tahoe-v1", Coordinator: program, Client: program, Port: 18080}
	if err := writeSeed(options, testDatabaseURL, backend); err != nil {
		t.Fatal(err)
	}
	plan, err := loadPlan(directory)
	if err != nil {
		t.Fatal(err)
	}
	var consumer, environment map[string]string
	for name, target := range map[string]*map[string]string{"consumer-env.json": &consumer, "coordinator-env.json": &environment} {
		data, err := readPrivate(filepath.Join(directory, name), 16384)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, target); err != nil {
			t.Fatal(err)
		}
	}
	return directory, plan, consumer, environment
}
