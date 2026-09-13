package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

type sandboxRecord struct {
	ID             string    `json:"id"`
	State          string    `json:"state"`
	BaseImageID    string    `json:"base_image_id"`
	CPUCount       uint16    `json:"cpu_count"`
	MemoryBytes    uint64    `json:"memory_bytes"`
	WorkspaceBytes uint64    `json:"workspace_bytes"`
	LeaseExpiresAt time.Time `json:"lease_expires_at"`
	ErrorCode      string    `json:"error_code,omitempty"`
}
type operationRecord struct {
	ID        string `json:"id"`
	State     string `json:"state"`
	ErrorCode string `json:"error_code,omitempty"`
}
type operationResponse struct {
	Sandbox   *sandboxRecord   `json:"sandbox,omitempty"`
	Operation *operationRecord `json:"operation"`
}

func (a *cli) create(ctx context.Context, args []string) error {
	flags := a.flags("create")
	image := flags.String("image", "", "qualified base image ID")
	cpu := flags.Uint("cpu", 4, "virtual CPUs")
	memory := flags.Uint64("memory-gib", 8, "guest RAM in GiB")
	workspace := flags.Uint64("workspace-gib", 25, "workspace capacity in GiB")
	wait := flags.Bool("wait", true, "wait until the sandbox is ready")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *image == "" || *cpu == 0 || *cpu > 64 || *memory < 2 || *memory > 512 || (*workspace != 25 && *workspace != 50) {
		return errors.New("create requires --image and supported CPU/RAM/workspace resources")
	}
	input := struct {
		BaseImageID string `json:"base_image_id"`
		CPU         uint   `json:"cpu_count"`
		Memory      uint64 `json:"memory_gib"`
		Workspace   uint64 `json:"workspace_gib"`
	}{*image, *cpu, *memory, *workspace}
	var result operationResponse
	if err := a.client.jsonRequest(ctx, http.MethodPost, "/v1/sandboxes", a.mutationKey(), input, &result); err != nil {
		return err
	}
	if result.Sandbox == nil || result.Operation == nil || validID(result.Sandbox.ID) != nil || validID(result.Operation.ID) != nil {
		return errors.New("create response is missing sandbox or operation identity")
	}
	if *wait {
		if err := a.waitOperation(ctx, result.Operation.ID); err != nil {
			return err
		}
		if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes/"+result.Sandbox.ID, "", nil, result.Sandbox); err != nil {
			return err
		}
	}
	if a.client.config.json {
		return a.writeJSON(result)
	}
	fmt.Fprintf(a.stdout, "%s %s (operation %s)\n", result.Sandbox.ID, result.Sandbox.State, result.Operation.ID)
	return nil
}

func (a *cli) list(ctx context.Context, args []string) error {
	flags := a.flags("list")
	limit := flags.Int("limit", 100, "maximum records, up to 1000")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *limit < 1 || *limit > 1000 {
		return errors.New("list accepts --limit between 1 and 1000")
	}
	var result struct {
		Data []sandboxRecord `json:"data"`
	}
	if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes?limit="+strconv.Itoa(*limit), "", nil, &result); err != nil {
		return err
	}
	if a.client.config.json {
		return a.writeJSON(result)
	}
	for _, sandbox := range result.Data {
		fmt.Fprintf(a.stdout, "%s\t%s\t%s\n", sandbox.ID, sandbox.State, sandbox.BaseImageID)
	}
	return nil
}

func (a *cli) inspect(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return errors.New("inspect requires SANDBOX_ID")
	}
	if err := validID(args[0]); err != nil {
		return err
	}
	var result sandboxRecord
	if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes/"+args[0], "", nil, &result); err != nil {
		return err
	}
	return a.showSandbox(result)
}

func (a *cli) showSandbox(result sandboxRecord) error {
	if a.client.config.json {
		return a.writeJSON(result)
	}
	fmt.Fprintf(a.stdout, "%s %s\nImage: %s; CPU: %d; RAM: %d GiB; workspace: %d GiB\nLease: %s\n", result.ID, result.State, result.BaseImageID, result.CPUCount, result.MemoryBytes>>30, result.WorkspaceBytes>>30, result.LeaseExpiresAt.Format(time.RFC3339))
	return nil
}

func (a *cli) lifecycle(ctx context.Context, action string, args []string) error {
	flags := a.flags(action)
	wait := flags.Bool("wait", true, "wait for the lifecycle result")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("%s requires SANDBOX_ID", action)
	}
	id := flags.Arg(0)
	if err := validID(id); err != nil {
		return err
	}
	method, path := http.MethodPost, "/v1/sandboxes/"+id+"/"+action
	if action == "delete" {
		method, path = http.MethodDelete, "/v1/sandboxes/"+id
	}
	var result operationResponse
	if err := a.client.jsonRequest(ctx, method, path, a.mutationKey(), nil, &result); err != nil {
		return err
	}
	if result.Operation == nil || validID(result.Operation.ID) != nil {
		return errors.New("lifecycle response is missing operation identity")
	}
	if *wait {
		if action == "delete" {
			for {
				var sandbox sandboxRecord
				if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandboxes/"+id, "", nil, &sandbox); err != nil {
					return err
				}
				if sandbox.State == "deleted" {
					return a.showSandbox(sandbox)
				}
				if sandbox.State == "failed" || sandbox.ErrorCode != "" {
					return errors.New("sandbox cleanup failed; capacity remains reserved")
				}
				if err := pause(ctx, a.pollInterval); err != nil {
					return err
				}
			}
		}
		if err := a.waitOperation(ctx, result.Operation.ID); err != nil {
			return err
		}
		return a.inspect(ctx, []string{id})
	}
	if a.client.config.json {
		return a.writeJSON(result)
	}
	fmt.Fprintf(a.stdout, "%s %s (operation %s)\n", id, action+" requested", result.Operation.ID)
	return nil
}

func (a *cli) waitOperation(ctx context.Context, id string) error {
	for {
		var response operationResponse
		if err := a.client.jsonRequest(ctx, http.MethodGet, "/v1/sandbox-operations/"+id, "", nil, &response); err != nil {
			return err
		}
		if response.Operation == nil {
			return errors.New("operation response is incomplete")
		}
		switch response.Operation.State {
		case "ready", "stopped", "deleted":
			return nil
		case "failed":
			return fmt.Errorf("sandbox operation %s failed", id)
		}
		if err := pause(ctx, a.pollInterval); err != nil {
			return err
		}
	}
}
