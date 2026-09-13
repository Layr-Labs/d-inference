package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

const workloadID = "darkbloom_sandbox_ci_v1"

type bundleManifest struct {
	SchemaVersion  int    `json:"schema_version"`
	Workload       string `json:"workload"`
	SDKHash        string `json:"sdk_sha256"`
	SourceHash     string `json:"source_sha256"`
	RunnerHash     string `json:"runner_sha256"`
	SDKTreeHash    string `json:"sdk_tree_sha256"`
	SourceTreeHash string `json:"source_tree_sha256"`
	GoVersion      string `json:"go_version"`
	GOOS           string `json:"goos"`
	GOARCH         string `json:"goarch"`
	GOMAXPROCS     int    `json:"gomaxprocs"`
	Commit         string `json:"source_commit"`
}

func main() {
	if err := execute(os.Args[1:]); err != nil {
		var reported reportedFailure
		if !errors.As(err, &reported) {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"schema_version": 1, "workload": workloadID, "status": "failed", "error": err.Error()})
		}
		os.Exit(1)
	}
}

type reportedFailure struct{ error }

func execute(arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("expected prepare or run")
	}
	flags := flag.NewFlagSet(arguments[0], flag.ContinueOnError)
	root := flags.String("root", "", "absolute private bundle directory")
	expected := flags.String("manifest-sha256", "", "exact manifest digest")
	runID := flags.String("run-id", "", "unique sample identifier")
	timeout := flags.Int("timeout-seconds", 840, "maximum complete workload duration")
	if err := flags.Parse(arguments[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || !filepath.IsAbs(*root) || !validDigest(*expected) || *timeout < 10 || *timeout > 840 {
		return errors.New("invalid runner arguments")
	}
	resolved, err := filepath.EvalSymlinks(*root)
	if err != nil || resolved != filepath.Clean(*root) {
		return errors.New("bundle root must be an existing canonical directory")
	}
	manifestPath := filepath.Join(*root, "manifest.json")
	if err := verifyFile(manifestPath, *expected); err != nil {
		return err
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return err
	}
	var manifest bundleManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return err
	}
	if manifest.SchemaVersion != 1 || manifest.Workload != workloadID || manifest.GOOS != runtime.GOOS || manifest.GOARCH != runtime.GOARCH ||
		manifest.GOMAXPROCS < 1 || manifest.GOMAXPROCS > 32 || !validDigest(manifest.SDKHash) || !validDigest(manifest.SourceHash) || !validDigest(manifest.RunnerHash) || !validDigest(manifest.SDKTreeHash) || !validDigest(manifest.SourceTreeHash) {
		return errors.New("bundle identity or platform mismatch")
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := verifyFile(executable, manifest.RunnerHash); err != nil {
		return err
	}
	switch arguments[0] {
	case "prepare":
		if err := unpackBundle(*root, manifest); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"status": "prepared", "manifest_sha256": *expected, "workload": workloadID})
	case "run":
		if !validRunID(*runID) {
			return errors.New("run-id must be 32 lowercase hex digits")
		}
		result, err := runWorkload(*root, *runID, manifest, *expected, *timeout)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
		}
		if encodeErr := json.NewEncoder(os.Stdout).Encode(result); encodeErr != nil {
			return encodeErr
		}
		if err != nil {
			return reportedFailure{err}
		}
		return nil
	default:
		return fmt.Errorf("unsupported runner action %q", arguments[0])
	}
}

func validRunID(value string) bool { return len(value) == 32 && validDigest(value+value) }
