package testbed

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

func (p *Provider) Start(ctx context.Context, coordinatorURL string, cfg ProviderConfig) error {
	if p.Target != nil {
		return p.startOwned(ctx, coordinatorURL, cfg)
	}
	binaryPath := p.BinaryPath
	if binaryPath == "" {
		binaryPath = findProviderBinary()
	}
	if binaryPath == "" {
		return fmt.Errorf("provider binary not found (set DARKBLOOM_PROVIDER_BINARY or ensure 'darkbloom' is in PATH)")
	}
	p.BinaryPath = binaryPath

	ctx, p.cancel = context.WithCancel(ctx)

	// Isolate the provider's persisted state per testbed instance. The
	// provider defaults these files to ~/.darkbloom/, which is shared by
	// every provider process on the machine (and across CI runs on a
	// persistent runner): test 1's provider would persist its loaded-model
	// set there, and test 2's freshly-booted provider would then
	// startup-preload + self-test it — behavior a fresh boot must not have.
	if p.StateDir == "" {
		stateDir, err := os.MkdirTemp("",
			"darkbloom-testbed-state-"+strconv.Itoa(p.ProviderIndex)+"-")
		if err != nil {
			return fmt.Errorf("create provider state dir: %w", err)
		}
		p.StateDir = stateDir
	}

	// The KV backend and the per-slot concurrency cap have no env-var or CLI
	// equivalent (DARKBLOOM_CBV2_PAGED_KV can only force paged OFF), so
	// selecting them adds keys to the testbed TOML. The file is always present
	// because it also disables auto-update and the launchd watchdog.
	spec, err := buildProviderStartSpec(coordinatorURL, p.StateDir, cfg, p.ProviderIndex)
	if err != nil {
		return err
	}
	generated := spec.Config
	args := spec.Arguments
	// Logged UNCONDITIONALLY, and before the file exists, because the case
	// worth seeing in a green log is the one that writes no file: a run nobody
	// pinned reads back "provider default" here instead of reading back
	// nothing at all.
	p.Logger.Info("provider KV posture",
		"provider", p.ProviderIndex,
		"posture", DescribeKVPosture(cfg))
	if generated != "" {
		configPath := filepath.Join(p.StateDir, "provider.toml")
		if err := os.WriteFile(configPath, []byte(generated), 0600); err != nil {
			return fmt.Errorf("write provider config: %w", err)
		}
		p.generatedConfig = generated
		if canonical := canonicalProviderConfigPath(); canonical != "" {
			_, statErr := os.Stat(canonical)
			p.canonicalConfigExisted = statErr == nil
		}
		p.Logger.Info("provider config written", "path", configPath)
	}

	if err := os.MkdirAll(filepath.Join(p.StateDir, "tmp"), 0700); err != nil {
		return err
	}
	cmd := execCommandContext(ctx, p.BinaryPath, args...)
	cmd.Stdout = &logWriter{logger: p.Logger, prefix: "provider:stdout"}
	cmd.Stderr = &logWriter{logger: p.Logger, prefix: "provider:stderr"}
	cmd.Env = os.Environ()
	for key, value := range spec.Environment {
		cmd.Env = append(cmd.Env, key+"="+value)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start provider: %w", err)
	}

	p.cmd = cmd.Process
	p.done = make(chan struct{})
	p.Logger.Info("provider started", "binary", p.BinaryPath, "pid", p.cmd.Pid)

	go func(done chan struct{}) {
		defer close(done)
		state, err := cmd.Process.Wait()
		if err != nil {
			p.Logger.Warn("provider process wait failed", "error", err)
			return
		}
		if state != nil && state.ExitCode() >= 0 {
			p.Logger.Warn("provider process exited", "exit_code", state.ExitCode())
		}
	}(p.done)

	return nil
}

// Running reports whether the real provider child is still alive.
func (p *Provider) Running() bool {
	if p.owned != nil {
		return p.owned.running()
	}
	if p.done == nil {
		return false
	}
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

// DaemonStatePath returns the isolated provider state snapshot path.
func (p *Provider) DaemonStatePath() string {
	if p.StateDir == "" {
		return ""
	}
	return filepath.Join(p.StateDir, "daemon-state.json")
}

func (p *Provider) stopLocal() {
	if p.cmd != nil {
		_ = p.cmd.Signal(os.Interrupt)
		select {
		case <-p.done:
		case <-time.After(10 * time.Second):
			_ = p.cmd.Kill()
			select {
			case <-p.done:
			case <-time.After(time.Second):
			}
		}
		p.cmd = nil
		p.done = nil
	}
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
	if p.AuthDir != "" {
		_ = os.RemoveAll(p.AuthDir)
	}
	if p.StateDir != "" {
		_ = os.RemoveAll(p.StateDir)
	}
	removeMigratedTestbedConfig(p.generatedConfig, p.canonicalConfigExisted)
	p.Logger.Info("provider stopped")
}
