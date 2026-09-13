package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var acceptanceDatabaseName = regexp.MustCompile(`^darkbloom_sandbox_acceptance_[a-z0-9_]{1,24}$`)

type seedOptions struct {
	Directory, DatabaseFile, BaseImage, Coordinator, Client string
	Port                                                    int
}

func (o seedOptions) validate() error {
	if !filepath.IsAbs(o.Directory) || !filepath.IsAbs(o.DatabaseFile) || !filepath.IsAbs(o.Coordinator) || !filepath.IsAbs(o.Client) ||
		o.Port < 1024 || o.Port > 65535 || !protocol.ValidSandboxIdentifier(o.BaseImage) {
		return errors.New("seed requires absolute paths, port 1024..65535 and a valid qualified base-image ID")
	}
	return nil
}

func validateDatabaseURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed == nil {
		return errors.New("invalid disposable database URL")
	}
	password, hasPassword := "", false
	if parsed.User != nil {
		password, hasPassword = parsed.User.Password()
	}
	port, portErr := strconv.Atoi(parsed.Port())
	if (parsed.Scheme != "postgres" && parsed.Scheme != "postgresql") || parsed.User == nil || parsed.User.Username() == "" || !hasPassword || password == "" ||
		parsed.Fragment != "" || parsed.Opaque != "" || portErr != nil || port < 1 || port > 65535 || !acceptanceDatabaseName.MatchString(strings.TrimPrefix(parsed.Path, "/")) {
		return errors.New("database must be an explicit credentialed loopback URL for darkbloom_sandbox_acceptance_<suffix>")
	}
	address := net.ParseIP(parsed.Hostname())
	if address == nil || !address.IsLoopback() {
		return errors.New("disposable database must use a loopback IP literal; remote databases require a private loopback tunnel")
	}
	query, err := url.ParseQuery(parsed.RawQuery)
	if err != nil || len(query) != 1 || len(query["sslmode"]) != 1 || query.Get("sslmode") != "disable" {
		return errors.New("database URL must contain only sslmode=disable; host/service overrides are forbidden")
	}
	return nil
}

func seedPostgres(options seedOptions) error {
	encoded, err := readPrivate(options.DatabaseFile, 4096)
	if err != nil {
		return err
	}
	databaseURL := strings.TrimSpace(string(encoded))
	if err := validateDatabaseURL(databaseURL); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	guard, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return errors.New("cannot connect to explicitly selected disposable database")
	}
	defer guard.Close(context.Background())
	// Serialize seed attempts and refuse every populated database before the
	// real store migration path can mutate it. No existing fixtures are reset.
	if _, err := guard.Exec(ctx, `SELECT pg_advisory_lock(7349236851)`); err != nil {
		return errors.New("cannot lock disposable fixture database")
	}
	var empty bool
	if err := guard.QueryRow(ctx, emptyFixtureDatabaseQuery).Scan(&empty); err != nil || !empty {
		return errors.New("fixture database must be empty; refusing migrations or writes to an existing database")
	}
	backend, err := store.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		return errors.New("disposable store migration failed")
	}
	defer backend.Close()
	return writeSeed(options, databaseURL, backend)
}

const emptyFixtureDatabaseQuery = `SELECT
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema')
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema')
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace
                    WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema')`

type seedStore interface {
	CreateUser(*store.User) error
	CreateAPIKey(string, store.APIKeyCreate) (string, *store.APIKey, error)
}

func writeSeed(options seedOptions, databaseURL string, backend seedStore) error {
	accountID := "sandbox-acceptance-" + uuid.NewString()
	user := &store.User{AccountID: accountID, PrivyUserID: "did:privy:fixture-" + uuid.NewString()}
	if err := backend.CreateUser(user); err != nil {
		return errors.New("could not create disposable consumer account")
	}
	expires := time.Now().UTC().Add(24 * time.Hour)
	key, _, err := backend.CreateAPIKey(accountID, store.APIKeyCreate{Name: "sandbox physical acceptance", ExpiresAt: &expires})
	if err != nil {
		return errors.New("could not mint disposable consumer API key")
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return errors.New("host credential randomness unavailable")
	}
	token := hex.EncodeToString(tokenBytes)
	hostID := uuid.NewString()
	hash := sha256.Sum256([]byte(token))
	hashes, _ := json.Marshal(map[string]string{hostID: hex.EncodeToString(hash[:])})
	apiURL := "http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(options.Port))
	plan := fixturePlan{SchemaVersion: 1, Status: "seeded", AccountID: accountID, HostID: hostID, APIURL: apiURL, HostURL: strings.Replace(apiURL, "http:", "ws:", 1) + "/ws/sandbox-host",
		BaseImage: options.BaseImage, Coordinator: options.Coordinator, Client: options.Client, KeyExpiresAt: expires}
	environment := coordinatorEnvironment(options.Directory, databaseURL, accountID, string(hashes), options.Port)
	for name, value := range map[string]any{"coordinator-env.json": environment, "consumer-env.json": map[string]string{"DARKBLOOM_API_KEY": key, "DARKBLOOM_API_URL": apiURL},
		"consumer-config.json": map[string]any{"environment": "nonproduction", "api_url": apiURL, "allow_insecure_localhost": true, "cli": options.Client, "base_image_id": options.BaseImage, "host_id": hostID, "cpu": 4, "memory_gib": 8, "workspace_gib": 25}} {
		if err := writePrivateJSON(filepath.Join(options.Directory, name), value); err != nil {
			return err
		}
	}
	if err := writePrivate(filepath.Join(options.Directory, "host-token"), []byte(token+"\n")); err != nil {
		return err
	}
	// Write completion last. Launchers reject partially seeded directories.
	return writePrivateJSON(filepath.Join(options.Directory, "fixture.json"), plan)
}
