package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type transferRecord struct {
	RequestID  string `json:"request_id"`
	TransferID string `json:"transfer_id"`
	State      string `json:"state"`
	Offset     uint64 `json:"offset"`
	Size       uint64 `json:"size"`
	SHA256     string `json:"sha256"`
}

func (a *cli) mkdir(ctx context.Context, args []string) error {
	if len(args) != 2 {
		return errors.New("mkdir requires SANDBOX_ID RELATIVE_DIRECTORY")
	}
	if err := validID(args[0]); err != nil {
		return err
	}
	if !protocol.ValidSandboxWorkspacePath(args[1]) {
		return errors.New("workspace paths must be relative without traversal")
	}
	var response struct {
		RequestID string `json:"request_id"`
	}
	if err := a.client.jsonRequest(ctx, http.MethodPost, "/v1/sandboxes/"+args[0]+"/files/directories", "", struct {
		Path string `json:"path"`
	}{args[1]}, &response); err != nil {
		return err
	}
	if a.client.config.json {
		return a.writeJSON(response)
	}
	fmt.Fprintf(a.stdout, "Created %s\n", args[1])
	return nil
}

func (a *cli) transfer(ctx context.Context, action string, args []string) error {
	if len(args) != 2 {
		return errors.New("upload status/abort requires SANDBOX_ID TRANSFER_ID")
	}
	if err := validID(args[0]); err != nil {
		return err
	}
	if err := validID(args[1]); err != nil {
		return err
	}
	method := http.MethodGet
	if action == "upload-abort" {
		method = http.MethodDelete
	}
	var response transferRecord
	if err := a.client.jsonRequest(ctx, method, transferPath(args[0], args[1]), "", nil, &response); err != nil {
		return err
	}
	return a.showTransfer(response)
}

func transferPath(sandboxID, transferID string) string {
	return "/v1/sandboxes/" + sandboxID + "/files/uploads/" + transferID
}

func (a *cli) showTransfer(transfer transferRecord) error {
	if a.client.config.json {
		return a.writeJSON(transfer)
	}
	fmt.Fprintf(a.stdout, "%s %s (%d/%d bytes)\n", transfer.TransferID, transfer.State, transfer.Offset, transfer.Size)
	return nil
}
