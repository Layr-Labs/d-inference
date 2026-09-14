package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

func (a *cli) upload(ctx context.Context, args []string) error {
	flags := a.flags("upload")
	transferID := flags.String("transfer-id", "", "resume the same transfer UUID")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 3 {
		return errors.New("upload requires SANDBOX_ID LOCAL_FILE RELATIVE_FILE")
	}
	sandboxID, localPath, remotePath := flags.Arg(0), flags.Arg(1), flags.Arg(2)
	if err := validID(sandboxID); err != nil {
		return err
	}
	if !protocol.ValidSandboxWorkspacePath(remotePath) {
		return errors.New("workspace file path must be relative without traversal")
	}
	file, before, err := openLocalRegularFile(localPath)
	if err != nil {
		return err
	}
	defer file.Close()
	if uint64(before.Size()) > protocol.SandboxMaximumFileBytes {
		return errors.New("file exceeds maximum sandbox workspace size")
	}
	digest, err := digestLocalFile(ctx, file)
	if err != nil {
		return err
	}
	if err := unchangedLocalFile(file, before); err != nil {
		return err
	}
	if *transferID == "" {
		*transferID = uuid.NewString()
	}
	if err := validID(*transferID); err != nil {
		return err
	}
	a.transferID = *transferID
	if !a.client.config.json {
		fmt.Fprintf(a.stderr, "Upload transfer %s\n", *transferID)
	}
	size := uint64(before.Size())
	input := struct {
		TransferID string `json:"transfer_id"`
		Path       string `json:"path"`
		Size       uint64 `json:"size"`
		SHA256     string `json:"sha256"`
	}{*transferID, remotePath, size, digest}
	var current transferRecord
	// Repeating begin proves the same path/size/digest, unlike accepting a
	// status for a caller-supplied transfer ID that might belong to another path.
	for attempt := 0; attempt < 3; attempt++ {
		err = a.client.jsonRequest(ctx, http.MethodPost, "/v1/sandboxes/"+sandboxID+"/files/uploads", "", input, &current)
		if err == nil {
			break
		}
		var remote *remoteError
		if errors.As(err, &remote) && remote.status < 500 || ctx.Err() != nil {
			return err
		}
	}
	if err != nil {
		return err
	}
	if err := validateUploadState(current, *transferID, size, digest); err != nil {
		return err
	}
	if current.State == "committed" {
		return a.showTransfer(current)
	}
	if err := a.client.jsonRequest(ctx, http.MethodGet, transferPath(sandboxID, *transferID), "", nil, &current); err != nil {
		return err
	}
	if err := validateUploadState(current, *transferID, size, digest); err != nil {
		return err
	}
	buffer := make([]byte, protocol.SandboxMaximumFileChunkBytes)
	for current.Offset < size {
		if err := ctx.Err(); err != nil {
			return err
		}
		amount := min(uint64(len(buffer)), size-current.Offset)
		chunk := buffer[:int(amount)]
		if _, err := file.ReadAt(chunk, int64(current.Offset)); err != nil {
			return errors.New("local upload source changed or cannot be read")
		}
		start := current.Offset
		var next transferRecord
		for attempt := 0; attempt < 3; attempt++ {
			path := transferPath(sandboxID, *transferID) + "/chunks?offset=" + strconv.FormatUint(start, 10)
			response, sendErr := a.client.request(ctx, http.MethodPut, path, "application/octet-stream", "", bytes.NewReader(chunk))
			if sendErr == nil {
				next, sendErr = readTransferResponse(response)
			}
			if sendErr == nil {
				if err := validateUploadState(next, *transferID, size, digest); err != nil {
					return err
				}
				if next.Offset != start+amount {
					return errors.New("host acknowledged an unexpected upload offset")
				}
				break
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// A response can be lost after the guest durably consumed this chunk.
			// Read the same transfer before deciding whether bytes must be resent.
			if err := a.client.jsonRequest(ctx, http.MethodGet, transferPath(sandboxID, *transferID), "", nil, &next); err != nil {
				return sendErr
			}
			if err := validateUploadState(next, *transferID, size, digest); err != nil {
				return err
			}
			if next.Offset == start+amount {
				break
			}
			if next.Offset != start || attempt == 2 {
				return sendErr
			}
		}
		current = next
	}
	if err := unchangedLocalFile(file, before); err != nil {
		return err
	}
	for attempt := 0; attempt < 3; attempt++ {
		err = a.client.jsonRequest(ctx, http.MethodPost, transferPath(sandboxID, *transferID)+"/commit", "", nil, &current)
		if err == nil {
			if err := validateUploadState(current, *transferID, size, digest); err != nil {
				return err
			}
			if current.State != "committed" {
				return errors.New("host did not confirm upload publication")
			}
			return a.showTransfer(current)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if readErr := a.client.jsonRequest(ctx, http.MethodGet, transferPath(sandboxID, *transferID), "", nil, &current); readErr != nil {
			return err
		}
		if err := validateUploadState(current, *transferID, size, digest); err != nil {
			return err
		}
		if current.State == "committed" {
			return a.showTransfer(current)
		}
	}
	return err
}

func readTransferResponse(response *http.Response) (transferRecord, error) {
	defer response.Body.Close()
	var transfer transferRecord
	encoded, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil || len(encoded) > 64*1024 {
		return transfer, errors.New("upload response is incomplete or too large")
	}
	if json.Unmarshal(encoded, &transfer) != nil {
		return transfer, errors.New("invalid upload response")
	}
	return transfer, nil
}

func validateUploadState(record transferRecord, id string, size uint64, digest string) error {
	if record.State == "aborted" {
		return errors.New("upload was aborted; start a new transfer")
	}
	if record.TransferID != id || record.Size != size || record.SHA256 != digest || record.Offset > size ||
		(record.State != "uploading" && record.State != "committed") || record.State == "committed" && record.Offset != size {
		return errors.New("upload metadata does not match the selected file")
	}
	return nil
}

func digestLocalFile(ctx context.Context, file *os.File) (string, error) {
	hash := sha256.New()
	buffer := make([]byte, protocol.SandboxMaximumFileChunkBytes)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, err := file.Read(buffer)
		if n > 0 {
			_, _ = hash.Write(buffer[:n])
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", errors.New("cannot hash local upload file")
		}
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
