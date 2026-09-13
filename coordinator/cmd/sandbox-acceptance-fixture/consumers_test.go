package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFixtureSeedsDistinctOrdinaryConsumersAndPrivateSecondKey(t *testing.T) {
	backend := store.NewMemory(store.Config{})
	directory, plan, primary, coordinator := seedMemoryFixture(t, backend)
	secondary, err := consumerEnvironment(directory, plan, true)
	if err != nil {
		t.Fatal(err)
	}
	if plan.SchemaVersion != 2 || plan.AccountID == plan.SecondaryAccountID || primary["DARKBLOOM_API_KEY"] == secondary["DARKBLOOM_API_KEY"] ||
		coordinator["EIGENINFERENCE_SANDBOX_ALLOWED_ACCOUNT_IDS"] != plan.allowedAccounts() {
		t.Fatal("fixture identities or enrollment are not distinct")
	}
	for account, consumer := range map[string]map[string]string{plan.AccountID: primary, plan.SecondaryAccountID: secondary} {
		user, err := backend.GetUserByAccountID(account)
		if err != nil || user.Role != "" {
			t.Fatal("fixture account is not an ordinary consumer")
		}
		key, err := backend.AuthenticateKey(consumer["DARKBLOOM_API_KEY"])
		if err != nil || key.OwnerAccountID != account || key.ExpiresAt == nil || !key.ExpiresAt.Equal(plan.KeyExpiresAt) ||
			time.Until(*key.ExpiresAt) < 23*time.Hour || time.Until(*key.ExpiresAt) > 24*time.Hour {
			t.Fatal("consumer key does not retain its own account and bounded expiry")
		}
	}
	for _, name := range []string{"fixture.json", "consumer-config.json", "secondary-consumer-env.json"} {
		data, err := readPrivate(filepath.Join(directory, name), 16384)
		if err != nil || strings.Contains(string(data), "private-password") || strings.Contains(string(data), "EIGENINFERENCE_DATABASE_URL") {
			t.Fatal("client-side fixture material exposed database credentials")
		}
		if name != "secondary-consumer-env.json" && (strings.Contains(string(data), primary["DARKBLOOM_API_KEY"]) || strings.Contains(string(data), secondary["DARKBLOOM_API_KEY"])) {
			t.Fatal("public fixture metadata exposed a consumer key")
		}
	}
}

func TestSecondConsumerLaunchAndAcceptanceKeepCredentialScopesSeparate(t *testing.T) {
	directory, plan, primary, _ := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	secondary, err := consumerEnvironment(directory, plan, true)
	if err != nil {
		t.Fatal(err)
	}
	_, args, environment, err := launchCommand(directory, plan, "run-secondary-client", []string{"list"})
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(environment, "\n")
	if !strings.Contains(joined, "DARKBLOOM_API_KEY="+secondary["DARKBLOOM_API_KEY"]) || strings.Contains(joined, primary["DARKBLOOM_API_KEY"]) ||
		strings.Contains(joined, "EIGENINFERENCE_") || strings.Contains(strings.Join(args, " "), secondary["DARKBLOOM_API_KEY"]) {
		t.Fatal("second consumer launcher mixed authority or exposed credentials")
	}
	harness := filepath.Join(directory, "harness.py")
	if err := os.WriteFile(harness, []byte("# offline fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	_, args, environment, err = acceptanceCommand(directory, plan, plan.Client, harness, filepath.Join(directory, "evidence"), false)
	if err != nil {
		t.Fatal(err)
	}
	joined = strings.Join(environment, "\n")
	if !strings.Contains(strings.Join(args, " "), "--second-account") ||
		strings.Contains(strings.Join(args, " "), primary["DARKBLOOM_API_KEY"]) || strings.Contains(strings.Join(args, " "), secondary["DARKBLOOM_API_KEY"]) ||
		!strings.Contains(joined, "DARKBLOOM_SECONDARY_API_KEY="+secondary["DARKBLOOM_API_KEY"]) ||
		!strings.Contains(joined, "DARKBLOOM_API_KEY="+primary["DARKBLOOM_API_KEY"]) || strings.Contains(joined, "EIGENINFERENCE_") {
		t.Fatal("acceptance launcher lost the second-account gate or mixed database authority")
	}
	encoded, _ := json.Marshal(primary)
	if err := os.WriteFile(filepath.Join(directory, "secondary-consumer-env.json"), encoded, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := launchCommand(directory, plan, "run-secondary-client", []string{"list"}); err == nil {
		t.Fatal("copied primary credentials counted as a second account")
	}
	if _, _, _, err := acceptanceCommand(directory, plan, plan.Client, harness, filepath.Join(directory, "evidence"), false); err == nil {
		t.Fatal("acceptance accepted duplicate consumer credentials")
	}
}

func TestLegacyFixtureCannotClaimSecondAccountAndIncompleteSecondSeedCannotLaunch(t *testing.T) {
	directory, plan, _, _ := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	plan.SchemaVersion, plan.SecondaryAccountID = 1, ""
	if _, _, _, err := launchCommand(directory, plan, "run-client", []string{"list"}); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := launchCommand(directory, plan, "run-secondary-client", []string{"list"}); err == nil {
		t.Fatal("legacy fixture claimed second-account support")
	}
	partial := t.TempDir()
	backend := &failSecondConsumer{MemoryStore: store.NewMemory(store.Config{})}
	if err := writeSeed(seedOptions{Directory: partial, Port: 18080}, testDatabaseURL, backend); err == nil {
		t.Fatal("second account failure was ignored")
	}
	if _, err := loadPlan(partial); err == nil {
		t.Fatal("partially seeded accounts became launchable")
	}
	if entries, err := os.ReadDir(partial); err != nil || len(entries) != 0 {
		t.Fatal("partial consumer failure published fixture credentials")
	}
}

func TestConsumerOnlyFixtureCanRelocateWithoutDatabaseOrHostCredentials(t *testing.T) {
	directory, plan, _, _ := seedMemoryFixture(t, store.NewMemory(store.Config{}))
	relocated := t.TempDir()
	for _, name := range []string{"fixture.json", "consumer-env.json", "secondary-consumer-env.json", "consumer-config.json"} {
		data, err := readPrivate(filepath.Join(directory, name), 16384)
		if err != nil {
			t.Fatal(err)
		}
		if err := writePrivate(filepath.Join(relocated, name), data); err != nil {
			t.Fatal(err)
		}
	}
	loaded, err := loadPlan(relocated)
	if err != nil || loaded != plan {
		t.Fatal("relocated public plan changed")
	}
	for _, mode := range []string{"run-client", "run-secondary-client"} {
		_, _, environment, err := launchCommand(relocated, loaded, mode, []string{"list"})
		if err != nil || !strings.Contains(strings.Join(environment, "\n"), "HOME="+filepath.Join(relocated, "home")) {
			t.Fatal("consumer launcher retained original fixture directory")
		}
	}
	harness := filepath.Join(relocated, "harness.py")
	if err := os.WriteFile(harness, []byte("# offline fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	_, args, environment, err := acceptanceCommand(relocated, loaded, plan.Client, harness, filepath.Join(relocated, "evidence"), false)
	if err != nil || !strings.Contains(strings.Join(args, " "), filepath.Join(relocated, "consumer-config.json")) ||
		strings.Contains(strings.Join(environment, "\n"), "EIGENINFERENCE_DATABASE_URL") {
		t.Fatal("relocated acceptance lost its local configuration or inherited database settings")
	}
	for _, name := range []string{"coordinator-env.json", "database-url.txt", "host-token"} {
		if _, err := os.Stat(filepath.Join(relocated, name)); !os.IsNotExist(err) {
			t.Fatal("consumer relocation copied non-consumer authority")
		}
	}
}

type failSecondConsumer struct {
	*store.MemoryStore
	created int
}

func (s *failSecondConsumer) CreateUser(user *store.User) error {
	s.created++
	if s.created == 2 {
		return errors.New("injected second consumer failure")
	}
	return s.MemoryStore.CreateUser(user)
}
