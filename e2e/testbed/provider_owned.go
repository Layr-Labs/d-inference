package testbed

import (
	"bufio"
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

//go:embed provider_host.py
var providerHostSource string

// commandFactory is the sole injected executable boundary used by CPU tests.
// Callers supply structured argv; no token or model bytes enter shell text.
type commandFactory func(string, ...string) *exec.Cmd

func shellWord(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'" }

func ownedHostCommand(target ProviderTarget, relayURL string) (string, []string, error) {
	port, err := loopbackRelayPort(relayURL)
	if err != nil {
		return "", nil, err
	}
	if err := target.validate(); err != nil {
		return "", nil, err
	}
	if target.SSH == nil {
		return "python3", []string{"-u", "-c", providerHostSource}, nil
	}
	ssh := target.SSH
	args := []string{"-T", "-i", ssh.IdentityFile, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
		"-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
		"-o", "ExitOnForwardFailure=yes", "-R", fmt.Sprintf("127.0.0.1:%d:127.0.0.1:%s", ssh.ForwardPort, port),
		ssh.Destination, shellWord(ssh.Python) + " -u -c " + shellWord(providerHostSource)}
	return "ssh", args, nil
}

type ownedHostEvent struct {
	AuthTokenRetired         *bool   `json:"auth_token_retired"`
	AuthTokenRetirementError *string `json:"auth_token_retirement_error"`
	RootCreated              *bool   `json:"root_created"`
	StopRequested            bool    `json:"stop_requested"`
	PGID                     int     `json:"pgid"`
	Seconds                  float64 `json:"seconds"`
	FixturePID               int     `json:"fixture_pid"`
	ProviderStarted          *bool   `json:"provider_started"`
	GroupCleanupComplete     *bool   `json:"group_cleanup_complete"`
	EntryReady               bool    `json:"entry_ready"`
	EntryReason              *string `json:"entry_reason"`

	RequestID   uint64          `json:"id"`
	Event       string          `json:"event"`
	PID         int             `json:"pid"`
	HostID      string          `json:"host_id"`
	Root        string          `json:"root"`
	Body        string          `json:"body"`
	Error       string          `json:"error"`
	ExitCode    *int            `json:"exit_code"`
	Failure     *string         `json:"failure"`
	Observation HostObservation `json:"observation"`
}

type ownedProvider struct {
	mu                sync.Mutex
	writeMu           sync.Mutex
	requestMu         sync.Mutex
	stdin             io.WriteCloser
	cmd               *exec.Cmd
	done              chan struct{}
	started           chan struct{}
	state             chan ownedHostEvent
	hostID            string
	pid               int
	entry             HostObservation
	credentialRetired *bool
	credentialError   *string
	cleanup           *HostObservation
	entryChecks       []ProviderEntryCheck
	fixturePID        int
	terminal          *ownedHostEvent
	err               error
	stopOnce          sync.Once
	nextRequestID     uint64
	activeRequestID   uint64
}

func (o *ownedProvider) send(command string) error {
	o.writeMu.Lock()
	defer o.writeMu.Unlock()
	_, err := io.WriteString(o.stdin, `{"command":"`+command+`"}`+"\n")
	return err
}
func (o *ownedProvider) running() bool {
	select {
	case <-o.done:
		return false
	default:
		return true
	}
}
func (o *ownedProvider) failure() error { o.mu.Lock(); defer o.mu.Unlock(); return o.err }

func startOwnedProvider(ctx context.Context, target ProviderTarget, spec ProviderStartSpec, token []byte, suiteNonce, relay string, factory commandFactory) (*ownedProvider, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	name, args, err := ownedHostCommand(target, relay)
	if err != nil {
		return nil, err
	}
	if len(token) == 0 || len(token) > 4096 {
		return nil, fmt.Errorf("bounded private provider token required")
	}
	request := struct {
		Target ProviderTarget    `json:"target"`
		Spec   ProviderStartSpec `json:"spec"`
		Token  string            `json:"auth_token"`
		Nonce  string            `json:"suite_nonce"`
	}{target, spec, base64.StdEncoding.EncodeToString(token), suiteNonce}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if len(encoded) > 1<<20 {
		return nil, fmt.Errorf("host launch description exceeds limit")
	}
	command := factory(name, args...)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, err
	}
	// Host provider output goes to the fresh host root. Helper errors are bounded
	// locally, exclude the private initial JSON and never mirror it to logs.
	stderr := &boundedHostError{}
	command.Stderr = stderr
	o := &ownedProvider{stdin: stdin, cmd: command, done: make(chan struct{}), started: make(chan struct{}), state: make(chan ownedHostEvent, 1)}
	if err := command.Start(); err != nil {
		stdin.Close()
		return nil, err
	}
	go func() {
		var scanErr error
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 4096), 2<<20)
		for scanner.Scan() {
			var event ownedHostEvent
			if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
				scanErr = fmt.Errorf("invalid owned helper event: %w", err)
				break
			}
			o.mu.Lock()
			if event.FixturePID > 0 {
				if o.fixturePID != 0 && event.FixturePID != o.fixturePID {
					scanErr = fmt.Errorf("fixture process identity changed")
				} else {
					o.fixturePID = event.FixturePID
				}
			}
			switch event.Event {
			case "entry":
				if len(o.entryChecks) >= 256 {
					scanErr = fmt.Errorf("too many prelaunch readiness observations")
				} else {
					o.entryChecks = append(o.entryChecks, ProviderEntryCheck{Observation: event.Observation, Ready: event.EntryReady, Reason: event.EntryReason})
				}
			case "prepared":
				o.hostID = event.HostID
				o.entry = event.Observation
			case "started":
				if scanErr != nil || o.terminal != nil || o.pid != 0 || o.hostID == "" || event.PID <= 0 {
					scanErr = fmt.Errorf("invalid helper start identity")
				} else {
					o.pid = event.PID
					close(o.started)
				}
			case "state", "observation":
				if event.RequestID == 0 || event.RequestID > o.nextRequestID {
					scanErr = fmt.Errorf("invalid control response identity")
				} else if event.RequestID == o.activeRequestID {
					select {
					case o.state <- event:
					default:
						scanErr = fmt.Errorf("duplicate control response")
					}
				} // Late responses to cancelled requests have no active authority.

			case "terminal":
				if o.terminal != nil {
					scanErr = errors.Join(scanErr, fmt.Errorf("duplicate terminal receipt"))
				}
				copied := event
				o.terminal = &copied
				_, _, identityErr := providerStartupIdentity(o.pid, o.terminal)
				scanErr = errors.Join(scanErr, identityErr)
			case "cleanup":
				o.credentialRetired, o.credentialError = event.AuthTokenRetired, event.AuthTokenRetirementError
				copied := event.Observation
				o.cleanup = &copied
			default:
				scanErr = fmt.Errorf("unknown owned helper event")
			}
			o.mu.Unlock()
			if scanErr != nil {
				break
			}
		}
		if scanErr == nil {
			scanErr = scanner.Err()
		}
		if scanErr != nil {
			_ = o.stdin.Close()
		}
		waitErr := command.Wait()
		o.mu.Lock()
		o.err = errors.Join(scanErr, waitErr)
		unstarted := o.terminal != nil && o.terminal.ProviderStarted != nil && !*o.terminal.ProviderStarted &&
			o.pid == 0 && o.terminal.PID == 0 && o.terminal.GroupCleanupComplete != nil && *o.terminal.GroupCleanupComplete
		if o.terminal == nil || (o.terminal.ExitCode == nil && !unstarted) {
			o.err = errors.Join(o.err, fmt.Errorf("owned process lacks terminal receipt"))
		}
		if o.terminal != nil && o.terminal.GroupCleanupComplete != nil && !*o.terminal.GroupCleanupComplete {
			o.err = errors.Join(o.err, fmt.Errorf("owned process group cleanup incomplete"))
		}
		if o.terminal != nil && o.terminal.Failure != nil {
			o.err = errors.Join(o.err, fmt.Errorf("owned process failed: %s", *o.terminal.Failure))
		}
		if o.credentialRetired != nil && !*o.credentialRetired {
			o.err = errors.Join(o.err, fmt.Errorf("owned credential retirement unconfirmed"))
		}
		if o.credentialError != nil {
			o.err = errors.Join(o.err, fmt.Errorf("owned credential retirement failed: %s", *o.credentialError))
		}
		if o.cleanup == nil {
			o.err = errors.Join(o.err, fmt.Errorf("owned host lacks cleanup receipt"))
		} else {
			o.err = errors.Join(o.err, o.cleanup.CleanupComplete())
		}
		if o.err != nil && stderr.String() != "" {
			o.err = fmt.Errorf("%w; helper: %s", o.err, stderr.String())
		}
		o.mu.Unlock()
		close(o.done)
	}()
	// The control pipe remains open until explicit shutdown; EOF/lease also
	// retires the exact host child if the controller disappears.
	if _, err = stdin.Write(append(encoded, '\n')); err != nil {
		stdin.Close()
		return o, err
	}
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-o.done:
				return
			case <-ctx.Done():
				_ = o.stop()
				return
			case <-ticker.C:
				if o.send("ping") != nil {
					_ = o.stdin.Close()
					return
				}
			}
		}
	}()
	// Lease pings and cancellation own preparation as well as the running child.
	select {
	case <-o.started:
		if err := ctx.Err(); err != nil {
			return o, errors.Join(err, o.stop())
		}
	case <-o.done:
		if err := ctx.Err(); err != nil {
			return o, errors.Join(err, o.failure())
		}
		if failure := o.failure(); failure != nil {
			return o, fmt.Errorf("owned helper ended before provider start acknowledgement: %w", failure)
		}
		return o, fmt.Errorf("owned helper ended before provider start acknowledgement")
	case <-ctx.Done():
		return o, errors.Join(ctx.Err(), o.stop())
	case <-time.After(5 * time.Minute):
		return o, errors.Join(fmt.Errorf("owned host preflight/start timed out"), o.stop())
	}
	return o, nil
}

type boundedHostError struct {
	mu   sync.Mutex
	body []byte
}

func (b *boundedHostError) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	remain := (16 << 10) - len(b.body)
	if remain > 0 {
		if len(p) > remain {
			p = p[:remain]
		}
		b.body = append(b.body, p...)
	}
	return n, nil
}
func (b *boundedHostError) String() string { b.mu.Lock(); defer b.mu.Unlock(); return string(b.body) }
