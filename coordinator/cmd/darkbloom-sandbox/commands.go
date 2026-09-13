package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

type commandRecord struct {
	ID                  string `json:"id"`
	SandboxID           string `json:"sandbox_id"`
	State               string `json:"state"`
	ExitCode            *int32 `json:"exit_code,omitempty"`
	StandardOutput      string `json:"stdout,omitempty"`
	StandardError       string `json:"stderr,omitempty"`
	CancellationPending bool   `json:"cancellation_pending"`
	OutputTruncated     bool   `json:"output_truncated"`
	ErrorCode           string `json:"error_code,omitempty"`
	PayloadExpired      bool   `json:"payload_expired"`
}
type commandResponse struct {
	Command *commandRecord `json:"command"`
}

type environmentFlags map[string]string

func (e environmentFlags) String() string { return "NAME=VALUE" }
func (e environmentFlags) Set(value string) error {
	key, content, ok := strings.Cut(value, "=")
	if !ok || key == "" {
		return errors.New("--env requires NAME=VALUE")
	}
	if _, exists := e[key]; exists {
		return fmt.Errorf("environment name %q is repeated", key)
	}
	e[key] = content
	return nil
}

func (a *cli) execute(ctx context.Context, args []string) (resultErr error) {
	delimiter := -1
	for index, argument := range args {
		if argument == "--" {
			delimiter = index
			break
		}
	}
	if delimiter < 0 || delimiter == len(args)-1 {
		return errors.New("exec requires SANDBOX_ID -- /absolute/executable [args]")
	}
	flags := a.flags("exec")
	directory := flags.String("cwd", "/workspace", "working directory under /workspace")
	timeout := flags.Uint("timeout", 900, "command timeout in seconds, up to 900")
	wait := flags.Bool("wait", true, "wait for command completion and print output")
	environment := environmentFlags{}
	flags.Var(environment, "env", "explicit environment NAME=VALUE; repeatable")
	if err := flags.Parse(args[:delimiter]); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return errors.New("exec requires one SANDBOX_ID before --")
	}
	id := flags.Arg(0)
	if err := validID(id); err != nil {
		return err
	}
	if *timeout < 1 || *timeout > 900 {
		return errors.New("command timeout must be between 1 and 900 seconds")
	}
	var wireEnvironment map[string]string
	if len(environment) > 0 {
		wireEnvironment = environment
	}
	arguments := args[delimiter+1:]
	if err := protocol.ValidateSandboxCommand(&protocol.SandboxCommandPayload{
		CommandID: uuid.NewString(), IdempotencyKey: a.mutationKey(),
		Scope:     protocol.SandboxScope{SandboxID: id, Generation: 1, FencingToken: 1},
		Arguments: arguments, Environment: wireEnvironment, WorkingDirectory: directory, TimeoutSeconds: uint32(*timeout),
	}); err != nil {
		return errors.New("command arguments, environment or workspace directory violate sandbox limits")
	}
	input := struct {
		Arguments        []string          `json:"arguments"`
		Environment      map[string]string `json:"environment,omitempty"`
		WorkingDirectory string            `json:"working_directory"`
		Timeout          uint32            `json:"timeout_seconds"`
	}{arguments, wireEnvironment, *directory, uint32(*timeout)}
	var response commandResponse
	if err := a.client.jsonRequest(ctx, http.MethodPost, "/v1/sandboxes/"+id+"/commands", a.mutationKey(), input, &response); err != nil {
		return err
	}
	if response.Command == nil || validID(response.Command.ID) != nil {
		return errors.New("exec response is missing command identity")
	}
	if !*wait {
		return a.showCommand(*response.Command, false)
	}
	command := response.Command
	defer func() {
		if ctx.Err() == nil || commandFinished(command) {
			return
		}
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		var cancelled commandResponse
		if err := a.client.jsonRequest(cleanup, http.MethodPost, "/v1/sandboxes/"+id+"/commands/"+command.ID+"/cancel", "", nil, &cancelled); err != nil {
			resultErr = fmt.Errorf("interrupted; command %s cancellation is unconfirmed", command.ID)
		} else {
			resultErr = fmt.Errorf("interrupted; cancellation requested for command %s", command.ID)
		}
	}()
	for !commandFinished(command) {
		if err := pause(ctx, a.pollInterval); err != nil {
			return err
		}
		if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes/"+id+"/commands/"+command.ID, "", nil, &response); err != nil {
			return err
		}
		if response.Command == nil || response.Command.ID != command.ID {
			return errors.New("command status is incomplete")
		}
		command = response.Command
	}
	if err := a.showCommand(*command, true); err != nil {
		return err
	}
	if command.State != "succeeded" {
		code := 1
		if command.ExitCode != nil && *command.ExitCode > 0 && *command.ExitCode < 126 {
			code = int(*command.ExitCode)
		}
		return commandExit{code: code}
	}
	return nil
}

func (a *cli) job(ctx context.Context, args []string) error {
	if len(args) == 2 && args[0] == "list" {
		if err := validID(args[1]); err != nil {
			return err
		}
		var response struct {
			Data []commandRecord `json:"data"`
		}
		if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes/"+args[1]+"/commands?limit=100", "", nil, &response); err != nil {
			return err
		}
		if a.client.config.json {
			return a.writeJSON(response)
		}
		for _, command := range response.Data {
			if err := a.showCommand(command, false); err != nil {
				return err
			}
		}
		return nil
	}
	if len(args) != 3 {
		return errors.New("job requires list SANDBOX_ID or status|logs|cancel SANDBOX_ID COMMAND_ID")
	}
	if args[0] != "status" && args[0] != "logs" && args[0] != "cancel" {
		return errors.New("unknown job action")
	}
	if err := validID(args[1]); err != nil {
		return err
	}
	if err := validID(args[2]); err != nil {
		return err
	}
	method, path := http.MethodGet, "/v1/sandboxes/"+args[1]+"/commands/"+args[2]
	if args[0] == "cancel" {
		method, path = http.MethodPost, path+"/cancel"
	}
	var response commandResponse
	if err := a.client.jsonRequest(ctx, method, path, "", nil, &response); err != nil {
		return err
	}
	if response.Command == nil {
		return errors.New("command status is incomplete")
	}
	return a.showCommand(*response.Command, args[0] == "logs")
}

func (a *cli) showCommand(command commandRecord, logs bool) error {
	if a.client.config.json {
		return a.writeJSON(command)
	}
	if logs {
		if command.PayloadExpired {
			fmt.Fprintf(a.stderr, "Command %s: %s (payload expired; output is no longer retained)\n", command.ID, command.State)
			return nil
		}
		if _, err := fmt.Fprint(a.stdout, command.StandardOutput); err != nil {
			return err
		}
		if _, err := fmt.Fprint(a.stderr, command.StandardError); err != nil {
			return err
		}
		fmt.Fprintf(a.stderr, "Command %s: %s", command.ID, command.State)
		if command.OutputTruncated {
			fmt.Fprint(a.stderr, " (output truncated)")
		}
		fmt.Fprintln(a.stderr)
		return nil
	}
	fmt.Fprintf(a.stdout, "%s %s", command.ID, command.State)
	if command.CancellationPending {
		fmt.Fprint(a.stdout, " (cleanup pending)")
	}
	if command.PayloadExpired {
		fmt.Fprint(a.stdout, " (payload expired)")
	}
	fmt.Fprintln(a.stdout)
	return nil
}

func commandFinished(command *commandRecord) bool {
	if command.CancellationPending {
		return false
	}
	switch command.State {
	case "succeeded", "failed", "timed_out", "cancelled", "lost":
		return true
	}
	return false
}
