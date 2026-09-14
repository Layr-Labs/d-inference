package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var packages = []string{"./coordinator/protocol", "./coordinator/sandboxhost", "./coordinator/sandboxcontrol"}

type testOutcome struct {
	Package       string `json:"package"`
	Passed        int    `json:"passed"`
	Skipped       int    `json:"skipped"`
	PackagePassed bool   `json:"package_passed"`
}
type sample struct {
	SchemaVersion int               `json:"schema_version"`
	Workload      string            `json:"workload"`
	Status        string            `json:"status"`
	ManifestHash  string            `json:"manifest_sha256"`
	RunID         string            `json:"run_id"`
	GoVersion     string            `json:"go_version"`
	GOOS          string            `json:"goos"`
	GOARCH        string            `json:"goarch"`
	GOMAXPROCS    int               `json:"gomaxprocs"`
	FreshCache    bool              `json:"fresh_gocache"`
	BuildSeconds  float64           `json:"build_seconds"`
	TestSeconds   float64           `json:"test_seconds"`
	InnerSeconds  float64           `json:"inner_seconds"`
	Artifacts     map[string]string `json:"artifacts_sha256"`
	Tests         []testOutcome     `json:"tests"`
	Invocations   []invocation      `json:"invocations"`
	EvidencePath  string            `json:"evidence_path,omitempty"`
	EvidenceHash  string            `json:"evidence_sha256,omitempty"`
	Error         string            `json:"error,omitempty"`
}

func runWorkload(root, runID string, manifest bundleManifest, manifestHash string, timeout int) (result sample, err error) {
	result = sample{SchemaVersion: 1, Workload: workloadID, Status: "failed", ManifestHash: manifestHash, RunID: runID, GoVersion: manifest.GoVersion,
		GOOS: runtime.GOOS, GOARCH: runtime.GOARCH, GOMAXPROCS: manifest.GOMAXPROCS, FreshCache: true, Artifacts: map[string]string{}}
	runRoot := filepath.Join(root, "runs", runID)
	if err = os.MkdirAll(filepath.Dir(runRoot), 0700); err != nil {
		return
	}
	if err = os.Mkdir(runRoot, 0700); err != nil {
		return
	}
	retained := filepath.Join(runRoot, "retained")
	temporary := filepath.Join(runRoot, "temporary")
	for _, name := range []string{retained, temporary, filepath.Join(temporary, "home"), filepath.Join(temporary, "cache"), filepath.Join(temporary, "modules"), filepath.Join(temporary, "tmp"), filepath.Join(temporary, "gopath")} {
		if err = os.Mkdir(name, 0700); err != nil {
			return
		}
	}
	defer os.RemoveAll(temporary)
	defer func() {
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
		}
		result.EvidencePath = filepath.ToSlash(filepath.Join("runs", runID, "evidence.tar.gz"))
		data, marshalErr := json.MarshalIndent(result, "", "  ")
		if marshalErr != nil {
			err = errors.Join(err, marshalErr)
			return
		}
		if writeErr := os.WriteFile(filepath.Join(retained, "sample.json"), append(data, '\n'), 0600); writeErr != nil {
			err = errors.Join(err, writeErr)
			return
		}
		evidence := filepath.Join(root, filepath.FromSlash(result.EvidencePath))
		if packErr := packEvidence(retained, evidence); packErr != nil {
			err = errors.Join(err, packErr)
			return
		}
		var hashErr error
		result.EvidenceHash, hashErr = fileDigest(evidence)
		err = errors.Join(err, hashErr)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	environment := workloadEnvironment(root, temporary, manifest)
	source := filepath.Join(root, "source")
	goBinary := filepath.Join(root, "go", "bin", "go")
	// Verify the exact extracted inputs each time, outside the timed region.
	// This also makes explicit that the OS page cache is not flushed.
	if err = verifyInputTrees(root, manifest); err != nil {
		return
	}
	invokeStep := func(command []string, log string) error {
		invocation, stepErr := invoke(ctx, source, environment, command, filepath.Join(retained, log))
		result.Invocations = append(result.Invocations, invocation)
		return stepErr
	}
	// The SDK identity check and cache directory setup are outside timed build.
	if err = invokeStep([]string{goBinary, "version"}, "go-version.log"); err != nil {
		return
	}
	version, readErr := os.ReadFile(filepath.Join(retained, "go-version.log"))
	if readErr != nil {
		err = readErr
		return
	}
	if strings.TrimSpace(string(version)) != "go version "+manifest.GoVersion+" "+manifest.GOOS+"/"+manifest.GOARCH {
		err = errors.New("SDK version/platform mismatch")
		return
	}
	buildStarted := time.Now()
	probe := filepath.Join(retained, "probe")
	// Compile one package at a time so multiple compiler subprocesses cannot
	// multiply the intended GOMAXPROCS CPU budget on the larger native host.
	common := []string{"-trimpath", "-buildvcs=false", "-ldflags=-buildid=", "-p", "1"}
	build := append([]string{goBinary, "build"}, common...)
	build = append(build, "-o", probe, "./benchmarkprobe")
	if err = invokeStep(build, "build-probe.log"); err != nil {
		return
	}
	for index, pkg := range packages {
		binary := filepath.Join(retained, fmt.Sprintf("tests-%d", index))
		command := append([]string{goBinary, "test", "-c"}, common...)
		command = append(command, "-o", binary, pkg)
		if err = invokeStep(command, fmt.Sprintf("compile-tests-%d.log", index)); err != nil {
			return
		}
	}
	result.BuildSeconds = time.Since(buildStarted).Seconds()
	testStarted := time.Now()
	if err = invokeStep([]string{probe}, "probe.json"); err != nil {
		return
	}
	if err = verifyProbe(filepath.Join(retained, "probe.json")); err != nil {
		return
	}
	for index, pkg := range packages {
		binary := filepath.Join(retained, fmt.Sprintf("tests-%d", index))
		log := fmt.Sprintf("tests-%d.jsonl", index)
		command := []string{goBinary, "tool", "test2json", "-t", "-p", pkg, binary, "-test.v=test2json", "-test.count=1", "-test.timeout=120s", "-test.parallel=" + strconv.Itoa(manifest.GOMAXPROCS)}
		invocation, stepErr := invoke(ctx, filepath.Join(source, strings.TrimPrefix(pkg, "./")), environment, command, filepath.Join(retained, log))
		result.Invocations = append(result.Invocations, invocation)
		if stepErr != nil {
			err = stepErr
			return
		}
		outcome, parseErr := readTestOutcome(filepath.Join(retained, log), pkg)
		if parseErr != nil {
			err = parseErr
			return
		}
		result.Tests = append(result.Tests, outcome)
	}
	result.TestSeconds = time.Since(testStarted).Seconds()
	result.InnerSeconds = result.BuildSeconds + result.TestSeconds
	for _, name := range []string{"probe", "tests-0", "tests-1", "tests-2"} {
		var hash string
		hash, err = fileDigest(filepath.Join(retained, name))
		if err != nil {
			return
		}
		result.Artifacts[name] = hash
	}
	result.Status = "passed"
	return
}

func verifyProbe(name string) error {
	data, err := os.ReadFile(name)
	if err != nil {
		return err
	}
	var actual map[string]any
	if err = json.Unmarshal(data, &actual); err != nil {
		return err
	}
	if actual["workload"] != workloadID || actual["protocol_version"] != float64(1) || actual["command_timeout_seconds"] != float64(900) || actual["host_id_header"] != "X-Darkbloom-Sandbox-Host-ID" || len(actual) != 4 {
		return errors.New("compiled probe returned an invalid result")
	}
	return nil
}

func readTestOutcome(name, pkg string) (testOutcome, error) {
	result := testOutcome{Package: pkg}
	file, err := os.Open(name)
	if err != nil {
		return result, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 65536), 2<<20)
	for scanner.Scan() {
		var event struct{ Action, Package, Test string }
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return result, err
		}
		if event.Package != pkg {
			return result, errors.New("test package identity mismatch")
		}
		switch event.Action {
		case "fail":
			return result, errors.New("unit test failure")
		case "pass":
			if event.Test == "" {
				result.PackagePassed = true
			} else {
				result.Passed++
			}
		case "skip":
			result.Skipped++
		}
	}
	if err := scanner.Err(); err != nil {
		return result, err
	}
	if !result.PackagePassed || result.Passed == 0 || result.Skipped != 0 {
		return result, errors.New("unit test evidence is incomplete or skipped work")
	}
	return result, nil
}
