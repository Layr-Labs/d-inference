package promptcontract

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const maxSupervisorReasonBytes = 512

type SupervisorConfig struct {
	Enabled                bool
	BinaryPath             string
	SocketPath             string
	ArtifactRoot           string
	ArtifactBaseURL        string
	ArtifactTimeout        time.Duration
	ProvisionWorkers       int
	ProvisionMaxModels     int
	HeaderReadTimeout      time.Duration
	RequestTimeout         time.Duration
	HealthTimeout          time.Duration
	PreloadTimeout         time.Duration
	StartupTimeout         time.Duration
	HealthInterval         time.Duration
	HealthFailureThreshold int
	ShutdownTimeout        time.Duration
	RestartBackoffMin      time.Duration
	RestartBackoffMax      time.Duration
	RestartWindow          time.Duration
	RestartMaxInWindow     int
	RestartCooldown        time.Duration
	StderrMaxBytes         int
	MaxBodyBytes           int
	MaxConcurrency         int
	MaxConnections         int
	MaxLoadedContracts     int
	MaxTokens              int
	MemoryLimitMiB         int
}

type SupervisorStatus struct {
	Enabled                   bool
	Running                   bool
	Ready                     bool
	Restarts                  uint64
	RSSBytes                  uint64
	ChildGeneration           uint64
	ConsecutiveHealthFailures int
	RestartReason             string
	LastExitReason            string
	StderrTail                string
	RestartSuppressedUntil    time.Time
}

type Supervisor struct {
	config SupervisorConfig
	client *Client

	mu                sync.RWMutex
	status            SupervisorStatus
	cancel            context.CancelFunc
	started           bool
	wg                sync.WaitGroup
	lastRestartReason string
}

func NewSupervisor(config SupervisorConfig) *Supervisor {
	applySupervisorDefaults(&config)
	return &Supervisor{
		config: config,
		client: NewClient(ClientConfig{
			SocketPath:      config.SocketPath,
			RequestTimeout:  config.RequestTimeout,
			HealthTimeout:   config.HealthTimeout,
			PreloadTimeout:  config.PreloadTimeout,
			MaxTokens:       config.MaxTokens,
			MaxPreloadIDs:   config.MaxLoadedContracts,
			MaxRequestBytes: int64(config.MaxBodyBytes),
		}),
		status: SupervisorStatus{Enabled: config.Enabled},
	}
}

func (s *Supervisor) Client() *Client {
	if s == nil {
		return nil
	}
	return s.client
}

func (s *Supervisor) Start(parent context.Context) {
	if s == nil {
		return
	}
	s.mu.Lock()
	if s.started || !s.config.Enabled {
		s.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	s.cancel = cancel
	s.started = true
	s.wg.Add(1)
	s.mu.Unlock()
	go s.run(ctx)
}

func (s *Supervisor) Close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	cancel := s.cancel
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.wg.Wait()
	s.client.Close()
}

func (s *Supervisor) Status() SupervisorStatus {
	if s == nil {
		return SupervisorStatus{}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.status
}

func (s *Supervisor) run(ctx context.Context) {
	defer s.wg.Done()
	backoff := s.config.RestartBackoffMin
	restartTimes := make([]time.Time, 0, s.config.RestartMaxInWindow)
	for ctx.Err() == nil {
		if delay := s.restartCircuitDelay(time.Now(), &restartTimes); delay > 0 {
			s.setRestartSuppressed(time.Now().Add(delay))
			if !sleepContext(ctx, delay) {
				break
			}
			continue
		}
		s.setRestartSuppressed(time.Time{})
		reason, detail, stderr, ran, stable := s.runChild(ctx)
		if ctx.Err() != nil {
			break
		}
		s.noteRestart(reason, detail, stderr)
		restartTimes = append(restartTimes, time.Now())
		if stable {
			backoff = s.config.RestartBackoffMin
		} else if ran {
			backoff = nextBackoff(backoff, s.config.RestartBackoffMax)
		} else {
			backoff = nextBackoff(backoff, s.config.RestartBackoffMax)
		}
		if !sleepContext(ctx, backoff) {
			break
		}
	}
	s.setStopped()
}

// runChild returns a bounded reason/detail/stderr record and whether the child
// started and ever answered liveness. Readiness degradation alone never ends
// the child; it only closes the cache-routing gate.
func (s *Supervisor) runChild(ctx context.Context) (string, string, string, bool, bool) {
	if err := prepareSocketDirectory(s.config.SocketPath); err != nil {
		return "socket_error", err.Error(), "", false, false
	}
	stderr := newTailBuffer(s.config.StderrMaxBytes)
	cmd := exec.Command(s.config.BinaryPath, s.arguments()...)
	cmd.Stdin = nil
	cmd.Stdout = io.Discard
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return "start_error", err.Error(), stderr.String(), false, false
	}
	generation := s.noteChildStarted(processRSSBytes(cmd.Process.Pid))
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()
	ticker := time.NewTicker(s.config.HealthInterval)
	defer ticker.Stop()
	startup := time.NewTimer(s.config.StartupTimeout)
	defer stopTimer(startup)
	live := false
	consecutiveFailures := 0
	for {
		select {
		case <-ctx.Done():
			s.terminate(cmd, waited)
			return "shutdown", "", stderr.String(), true, live
		case err := <-waited:
			detail := childExitReason(err, cmd.ProcessState)
			s.setChildStopped(generation)
			return "child_exit", detail, stderr.String(), true, live
		case <-startup.C:
			if !live {
				s.terminate(cmd, waited)
				s.setChildStopped(generation)
				return "startup_timeout", "liveness startup deadline exceeded", stderr.String(), true, false
			}
		case <-ticker.C:
			rss := processRSSBytes(cmd.Process.Pid)
			if exceedsRSSLimit(rss, s.config.MemoryLimitMiB) {
				s.setRuntimeState(generation, true, false, rss, consecutiveFailures)
				s.terminate(cmd, waited)
				s.setChildStopped(generation)
				return "rss_limit", fmt.Sprintf("RSS %d exceeded %d MiB", rss, s.config.MemoryLimitMiB), stderr.String(), true, live
			}
			if err := s.client.Health(ctx); err != nil {
				if live {
					consecutiveFailures++
				}
				s.setRuntimeState(generation, true, false, rss, consecutiveFailures)
				if live && consecutiveFailures >= s.config.HealthFailureThreshold {
					s.terminate(cmd, waited)
					s.setChildStopped(generation)
					return "health_failure_threshold", err.Error(), stderr.String(), true, true
				}
				continue
			}
			if !live {
				live = true
				stopTimer(startup)
			}
			consecutiveFailures = 0
			ready, err := s.client.Ready(ctx)
			if err != nil {
				ready = false
			}
			s.setRuntimeState(generation, true, ready, rss, 0)
		}
	}
}

func prepareSocketDirectory(socketPath string) error {
	directory := filepath.Dir(socketPath)
	opened, err := secureOpenAbsoluteDirectory(directory, true, 0o700)
	if err != nil {
		return err
	}
	defer opened.Close()
	info, err := opened.Stat()
	if err != nil || !info.IsDir() {
		return ErrInvalidConfig
	}
	return opened.Chmod(0o700)
}

func (s *Supervisor) arguments() []string {
	return []string{
		"--socket", s.config.SocketPath,
		"--artifact-root", s.config.ArtifactRoot,
		"--max-body-bytes", strconv.Itoa(s.config.MaxBodyBytes),
		"--max-concurrency", strconv.Itoa(s.config.MaxConcurrency),
		"--max-connections", strconv.Itoa(s.config.MaxConnections),
		"--max-loaded-contracts", strconv.Itoa(s.config.MaxLoadedContracts),
		"--max-tokens", strconv.Itoa(s.config.MaxTokens),
		"--header-read-timeout-ms", strconv.FormatInt(s.config.HeaderReadTimeout.Milliseconds(), 10),
		"--request-timeout-ms", strconv.FormatInt(s.config.RequestTimeout.Milliseconds(), 10),
		"--memory-limit-mib", strconv.Itoa(s.config.MemoryLimitMiB),
		"--parent-pid", strconv.Itoa(os.Getpid()),
	}
}

func (s *Supervisor) terminate(cmd *exec.Cmd, waited <-chan error) {
	if cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	timer := time.NewTimer(s.config.ShutdownTimeout)
	defer timer.Stop()
	select {
	case <-waited:
	case <-timer.C:
		_ = cmd.Process.Kill()
		<-waited
	}
}
