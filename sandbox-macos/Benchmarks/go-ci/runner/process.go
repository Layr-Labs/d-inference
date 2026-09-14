package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type invocation struct {
	Arguments      []string `json:"arguments"`
	ElapsedSeconds float64  `json:"elapsed_seconds"`
	ExitCode       int      `json:"exit_code"`
	Log            string   `json:"log"`
}

func workloadEnvironment(root, temporary string, manifest bundleManifest) []string {
	return []string{
		"PATH=" + filepath.Join(root, "go", "bin") + ":/usr/bin:/bin", "HOME=" + filepath.Join(temporary, "home"),
		"GOROOT=" + filepath.Join(root, "go"), "GOTOOLCHAIN=local", "GOENV=off", "CGO_ENABLED=0", "GOPROXY=off", "GOSUMDB=off", "GOVCS=*:off", "GOTELEMETRY=off",
		"GOOS=" + manifest.GOOS, "GOARCH=" + manifest.GOARCH, "GOMAXPROCS=" + strconv.Itoa(manifest.GOMAXPROCS),
		"GOCACHE=" + filepath.Join(temporary, "cache"), "GOMODCACHE=" + filepath.Join(temporary, "modules"),
		"GOPATH=" + filepath.Join(temporary, "gopath"), "TMPDIR=" + filepath.Join(temporary, "tmp"),
		"LANG=C", "LC_ALL=C", "TZ=UTC", "GOWORK=off", "GOFLAGS=-mod=vendor",
	}
}

type boundedLog struct {
	file      *os.File
	remaining int64
}

func (w *boundedLog) Write(data []byte) (int, error) {
	if int64(len(data)) > w.remaining {
		return 0, errors.New("workload log exceeds 32 MiB")
	}
	n, err := w.file.Write(data)
	w.remaining -= int64(n)
	return n, err
}

func invoke(ctx context.Context, directory string, environment, command []string, logPath string) (invocation, error) {
	result := invocation{Arguments: command, Log: filepath.Base(logPath), ExitCode: -1}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0600)
	if err != nil {
		return result, err
	}
	defer log.Close()
	process := exec.CommandContext(ctx, command[0], command[1:]...)
	process.Dir = directory
	process.Env = environment
	process.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	process.Cancel = func() error { return syscall.Kill(-process.Process.Pid, syscall.SIGKILL) }
	process.WaitDelay = 5 * time.Second
	writer := &boundedLog{file: log, remaining: 32 << 20}
	process.Stdout = writer
	process.Stderr = writer
	started := time.Now()
	err = process.Run()
	result.ElapsedSeconds = time.Since(started).Seconds()
	if process.ProcessState != nil {
		result.ExitCode = process.ProcessState.ExitCode()
	}
	if err != nil {
		return result, fmt.Errorf("%s failed; see %s: %w", filepath.Base(command[0]), filepath.Base(logPath), err)
	}
	return result, nil
}
