package promptcontract

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type SupervisorConfig struct {
	Enabled            bool
	BinaryPath         string
	SocketPath         string
	ArtifactRoot       string
	ArtifactBaseURL    string
	ArtifactTimeout    time.Duration
	ProvisionWorkers   int
	ProvisionMaxModels int
	HeaderReadTimeout  time.Duration
	RequestTimeout     time.Duration
	StartupTimeout     time.Duration
	HealthInterval     time.Duration
	ShutdownTimeout    time.Duration
	RestartBackoffMin  time.Duration
	RestartBackoffMax  time.Duration
	MaxBodyBytes       int
	MaxConcurrency     int
	MaxConnections     int
	MaxLoadedContracts int
	MaxTokens          int
	MemoryLimitMiB     int
}

type SupervisorStatus struct {
	Enabled  bool
	Running  bool
	Ready    bool
	Restarts uint64
	RSSBytes uint64
}

type Supervisor struct {
	config SupervisorConfig
	client *Client

	mu      sync.RWMutex
	status  SupervisorStatus
	cancel  context.CancelFunc
	started bool
	wg      sync.WaitGroup
}

func NewSupervisor(config SupervisorConfig) *Supervisor {
	applySupervisorDefaults(&config)
	return &Supervisor{
		config: config,
		client: NewClient(ClientConfig{
			SocketPath:     config.SocketPath,
			RequestTimeout: config.RequestTimeout,
			MaxTokens:      config.MaxTokens,
		}),
		status: SupervisorStatus{Enabled: config.Enabled},
	}
}

func (s *Supervisor) Client() *Client {
	return s.client
}

func (s *Supervisor) Start(parent context.Context) {
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
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.status
}

func (s *Supervisor) run(ctx context.Context) {
	defer s.wg.Done()
	backoff := s.config.RestartBackoffMin
	for {
		if ctx.Err() != nil {
			s.setState(false, false)
			return
		}
		if err := prepareSocketDirectory(s.config.SocketPath); err != nil {
			s.noteRestart()
			if !sleepContext(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff, s.config.RestartBackoffMax)
			continue
		}
		cmd := exec.Command(s.config.BinaryPath, s.arguments()...)
		cmd.Stdin = nil
		cmd.Stdout = io.Discard
		cmd.Stderr = io.Discard
		if err := cmd.Start(); err != nil {
			s.noteRestart()
			if !sleepContext(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff, s.config.RestartBackoffMax)
			continue
		}
		s.setStateWithRSS(true, false, processRSSBytes(cmd.Process.Pid))
		waited := make(chan error, 1)
		go func() { waited <- cmd.Wait() }()
		ticker := time.NewTicker(s.config.HealthInterval)
		startup := time.NewTimer(s.config.StartupTimeout)
		ready := false
		restart := false
		for !restart {
			select {
			case <-ctx.Done():
				stopTimer(startup)
				ticker.Stop()
				s.terminate(cmd, waited)
				s.setState(false, false)
				return
			case <-waited:
				stopTimer(startup)
				ticker.Stop()
				s.setState(false, false)
				restart = true
			case <-startup.C:
				if !ready {
					ticker.Stop()
					s.terminate(cmd, waited)
					s.setState(false, false)
					restart = true
				}
			case <-ticker.C:
				healthCtx, cancel := context.WithTimeout(ctx, s.config.RequestTimeout)
				err := s.client.Health(healthCtx)
				cancel()
				if err == nil {
					if !ready {
						ready = true
						backoff = s.config.RestartBackoffMin
						stopTimer(startup)
					}
					s.setStateWithRSS(true, true, processRSSBytes(cmd.Process.Pid))
				} else if ready {
					stopTimer(startup)
					ticker.Stop()
					s.setState(true, false)
					s.terminate(cmd, waited)
					s.setState(false, false)
					restart = true
				}
			}
		}
		s.noteRestart()
		if !sleepContext(ctx, backoff) {
			return
		}
		backoff = nextBackoff(backoff, s.config.RestartBackoffMax)
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

func (s *Supervisor) setState(running, ready bool) {
	s.setStateWithRSS(running, ready, 0)
}

func (s *Supervisor) setStateWithRSS(running, ready bool, rssBytes uint64) {
	s.mu.Lock()
	s.status.Running = running
	s.status.Ready = ready
	if running {
		s.status.RSSBytes = rssBytes
	} else {
		s.status.RSSBytes = 0
	}
	s.mu.Unlock()
}

func (s *Supervisor) noteRestart() {
	s.mu.Lock()
	s.status.Restarts++
	s.mu.Unlock()
}

func applySupervisorDefaults(config *SupervisorConfig) {
	if config.BinaryPath == "" {
		config.BinaryPath = "promptsidecar"
	}
	if config.SocketPath == "" {
		config.SocketPath = DefaultSocketPath
	}
	if config.ArtifactRoot == "" {
		config.ArtifactRoot = DefaultArtifactRoot
	}
	if config.ArtifactBaseURL == "" {
		config.ArtifactBaseURL = "https://models.darkbloom.ai"
	}
	if config.ArtifactTimeout <= 0 {
		config.ArtifactTimeout = defaultDownloadTimeout
	}
	if config.ProvisionWorkers <= 0 {
		config.ProvisionWorkers = defaultProvisionConcurrency
	}
	if config.ProvisionMaxModels <= 0 {
		config.ProvisionMaxModels = defaultProvisionMaxModels
	}
	if config.HeaderReadTimeout <= 0 {
		config.HeaderReadTimeout = DefaultRequestTimeout
	}
	if config.RequestTimeout <= 0 {
		config.RequestTimeout = DefaultRequestTimeout
	}
	if config.StartupTimeout <= 0 {
		config.StartupTimeout = 5 * time.Second
	}
	if config.HealthInterval <= 0 {
		config.HealthInterval = 100 * time.Millisecond
	}
	if config.ShutdownTimeout <= 0 {
		config.ShutdownTimeout = 2 * time.Second
	}
	if config.RestartBackoffMin <= 0 {
		config.RestartBackoffMin = 100 * time.Millisecond
	}
	if config.RestartBackoffMax < config.RestartBackoffMin {
		config.RestartBackoffMax = 5 * time.Second
	}
	if config.MaxBodyBytes <= 0 {
		config.MaxBodyBytes = DefaultMaxRequestBytes
	}
	if config.MaxConcurrency <= 0 {
		config.MaxConcurrency = 4
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 64
	}
	if config.MaxLoadedContracts <= 0 {
		config.MaxLoadedContracts = 8
	}
	if config.MaxTokens <= 0 {
		config.MaxTokens = DefaultMaxTokens
	}
	if config.MemoryLimitMiB <= 0 {
		config.MemoryLimitMiB = 1024
	}
}

func sleepContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func nextBackoff(current, maximum time.Duration) time.Duration {
	if current >= maximum/2 {
		return maximum
	}
	return current * 2
}

func stopTimer(timer *time.Timer) {
	if timer == nil || !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
}

func processRSSBytes(pid int) uint64 {
	if pid <= 0 {
		return 0
	}
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/statm")
	if err != nil {
		return 0
	}
	return rssBytesFromStatm(data, os.Getpagesize())
}

func rssBytesFromStatm(data []byte, pageSize int) uint64 {
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0
	}
	residentPages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	if pageSize <= 0 || residentPages > ^uint64(0)/uint64(pageSize) {
		return 0
	}
	return residentPages * uint64(pageSize)
}
