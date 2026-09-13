package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func baseEnvironment(directory string) map[string]string {
	return map[string]string{"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": filepath.Join(directory, "home"), "LANG": "C", "TZ": "UTC"}
}

func coordinatorEnvironment(directory, databaseURL, accountID, hashes string, port int) map[string]string {
	environment := baseEnvironment(directory)
	for key, value := range map[string]string{
		"EIGENINFERENCE_DATABASE_URL": databaseURL, "EIGENINFERENCE_ALLOW_MEMORY_STORE": "false",
		"EIGENINFERENCE_BIND_HOST": "127.0.0.1", "EIGENINFERENCE_PORT": strconv.Itoa(port),
		"EIGENINFERENCE_BASE_URL":                "http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		"EIGENINFERENCE_SANDBOX_SERVICE_ENABLED": "true", "EIGENINFERENCE_SANDBOX_ADMISSION_ENABLED": "true",
		"EIGENINFERENCE_SANDBOX_ALLOWED_ACCOUNT_IDS": accountID, "EIGENINFERENCE_SANDBOX_HOST_TOKEN_SHA256_JSON": hashes,
		"EIGENINFERENCE_SANDBOX_COMMAND_PAYLOAD_RETENTION": "24h", "EIGENINFERENCE_WARM_POOL_ENABLED": "false",
		"EIGENINFERENCE_BASE_REWARDS": "false", "EIGENINFERENCE_PROMPT_SIDECAR_ENABLED": "false",
		"EIGENINFERENCE_TRUST_REUSE_REVOCATION_JOURNAL_PATH": filepath.Join(directory, "trust-revocations.jsonl"),
		"EIGENINFERENCE_DRAIN_GRACE":                         "30s",
	} {
		environment[key] = value
	}
	return environment
}

func launchCommand(directory string, plan fixturePlan, mode string, arguments []string) (string, []string, []string, error) {
	origin, err := url.Parse(plan.APIURL)
	port := 0
	if err == nil {
		port, _ = strconv.Atoi(origin.Port())
	}
	if err != nil || origin.Scheme != "http" || origin.Hostname() != "127.0.0.1" || origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" ||
		port < 1024 || port > 65535 || !protocol.ValidSandboxUUID(plan.HostID) || plan.AccountID == "" {
		return "", nil, nil, errors.New("fixture must retain its explicit loopback origin and identities")
	}
	environment := baseEnvironment(directory)
	program := plan.Client
	var childArgs []string
	if mode == "run-coordinator" {
		if len(arguments) != 0 {
			return "", nil, nil, errors.New("coordinator fixture launch does not accept extra arguments")
		}
		data, err := readPrivate(filepath.Join(directory, "coordinator-env.json"), 16384)
		if err != nil {
			return "", nil, nil, err
		}
		var stored map[string]string
		if json.Unmarshal(data, &stored) != nil {
			return "", nil, nil, errors.New("invalid coordinator fixture environment")
		}
		databaseURL := stored["EIGENINFERENCE_DATABASE_URL"]
		if err := validateDatabaseURL(databaseURL); err != nil {
			return "", nil, nil, err
		}
		token, err := readPrivate(filepath.Join(directory, "host-token"), 512)
		if err != nil {
			return "", nil, nil, err
		}
		hash := sha256.Sum256([]byte(strings.TrimSpace(string(token))))
		hashes, _ := json.Marshal(map[string]string{plan.HostID: hex.EncodeToString(hash[:])})
		environment = coordinatorEnvironment(directory, databaseURL, plan.allowedAccounts(), string(hashes), port)
		if !reflect.DeepEqual(environment, stored) {
			return "", nil, nil, errors.New("coordinator environment differs from the isolated fixture contract")
		}
		program = plan.Coordinator
	} else {
		if (mode != "run-client" && mode != "run-secondary-client") || len(arguments) == 0 || strings.HasPrefix(arguments[0], "-") {
			return "", nil, nil, errors.New("client launch requires a subcommand; global endpoint overrides are forbidden")
		}
		consumer, err := consumerEnvironment(directory, plan, mode == "run-secondary-client")
		if err != nil {
			return "", nil, nil, err
		}
		for key, value := range consumer {
			environment[key] = value
		}
		childArgs = append([]string{"--json", "--api-url", plan.APIURL, "--allow-insecure-localhost"}, arguments...)
	}
	info, err := os.Lstat(program)
	if !filepath.IsAbs(program) || err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return "", nil, nil, errors.New("fixture program must be an explicit regular executable")
	}
	keys := make([]string, 0, len(environment))
	for key := range environment {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	encoded := make([]string, 0, len(keys))
	for _, key := range keys {
		encoded = append(encoded, key+"="+environment[key])
	}
	return program, childArgs, encoded, nil
}

func acceptanceCommand(directory string, plan fixturePlan, python, harness, evidence string, quota bool) (string, []string, []string, error) {
	// Reuse the credential/origin checks and clean consumer environment; the
	// real acceptance harness then invokes the configured standalone CLI.
	_, _, environment, err := launchCommand(directory, plan, "run-client", []string{"list"})
	if err != nil {
		return "", nil, nil, err
	}
	for _, name := range []string{python, harness} {
		info, err := os.Lstat(name)
		if !filepath.IsAbs(name) || err != nil || !info.Mode().IsRegular() {
			return "", nil, nil, errors.New("acceptance requires absolute regular Python and harness paths")
		}
	}
	if !filepath.IsAbs(evidence) {
		return "", nil, nil, errors.New("acceptance evidence path must be absolute and new")
	}
	if _, err := os.Lstat(evidence); !os.IsNotExist(err) {
		return "", nil, nil, errors.New("acceptance evidence directory already exists")
	}
	configFile := filepath.Join(directory, "consumer-config.json")
	data, err := readPrivate(configFile, 16384)
	if err != nil {
		return "", nil, nil, err
	}
	var config map[string]any
	if json.Unmarshal(data, &config) != nil || config["environment"] != "nonproduction" || config["api_url"] != plan.APIURL || config["cli"] != plan.Client || config["host_id"] != plan.HostID || config["base_image_id"] != plan.BaseImage {
		return "", nil, nil, errors.New("acceptance configuration differs from the seeded fixture")
	}
	args := []string{"-B", harness, "--config", configFile, "--output", evidence}
	if plan.SchemaVersion == 2 {
		secondary, err := consumerEnvironment(directory, plan, true)
		if err != nil {
			return "", nil, nil, err
		}
		environment = append(environment, "DARKBLOOM_SECONDARY_API_KEY="+secondary["DARKBLOOM_API_KEY"])
		args = append(args, "--second-account")
	}
	if quota {
		args = append(args, "--workspace-exhaustion")
	}
	return python, args, environment, nil
}
