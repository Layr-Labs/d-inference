package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (a *cli) download(ctx context.Context, args []string) error {
	if len(args) != 3 {
		return errors.New("download requires SANDBOX_ID RELATIVE_FILE LOCAL_FILE")
	}
	if err := validID(args[0]); err != nil {
		return err
	}
	if !protocol.ValidSandboxWorkspacePath(args[1]) {
		return errors.New("workspace file path must be relative without traversal")
	}
	download, err := newLocalDownload(args[2])
	if err != nil {
		return err
	}
	defer download.close()
	var offset, total uint64
	version := ""
	for {
		query := url.Values{"path": {args[1]}, "offset": {strconv.FormatUint(offset, 10)}, "length": {strconv.Itoa(protocol.SandboxMaximumFileChunkBytes)}}
		if version != "" {
			query.Set("version", version)
		}
		response, err := a.client.request(ctx, http.MethodGet, "/v1/sandboxes/"+args[0]+"/files?"+query.Encode(), "", "", nil)
		if err != nil {
			return err
		}
		chunk, size, returnedVersion, err := readDownloadChunk(response, offset, version)
		if err != nil {
			return err
		}
		if version == "" {
			total, version = size, returnedVersion
		} else if total != size {
			return errors.New("download file size changed; partial output discarded")
		}
		if _, err := download.file.Write(chunk); err != nil {
			return errors.New("cannot write download staging file")
		}
		offset += uint64(len(chunk))
		if offset == total {
			break
		}
		if len(chunk) == 0 {
			return errors.New("download ended before its declared size")
		}
	}
	if err := download.publish(); err != nil {
		return err
	}
	result := struct {
		Path    string `json:"path"`
		Size    uint64 `json:"size"`
		Version string `json:"version"`
	}{download.outputPath, total, version}
	if a.client.config.json {
		return a.writeJSON(result)
	}
	fmt.Fprintf(a.stdout, "Saved %s (%d bytes)\n", download.outputPath, total)
	return nil
}

func readDownloadChunk(response *http.Response, expectedOffset uint64, expectedVersion string) ([]byte, uint64, string, error) {
	defer response.Body.Close()
	contentType, _, typeErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	offset, offsetErr := strconv.ParseUint(response.Header.Get("X-Sandbox-File-Offset"), 10, 64)
	size, sizeErr := strconv.ParseUint(response.Header.Get("X-Sandbox-File-Size"), 10, 64)
	digest, version := response.Header.Get("X-Sandbox-Chunk-SHA256"), response.Header.Get("X-Sandbox-File-Version")
	if typeErr != nil || contentType != "application/octet-stream" || offsetErr != nil || sizeErr != nil || offset != expectedOffset ||
		size > protocol.SandboxMaximumFileBytes || offset > size || !protocol.ValidSandboxFileDigest(digest) ||
		!protocol.ValidSandboxFileDigest(version) || expectedVersion != "" && expectedVersion != version {
		return nil, 0, "", errors.New("download metadata or file revision changed; partial output discarded")
	}
	chunk, err := io.ReadAll(io.LimitReader(response.Body, protocol.SandboxMaximumFileChunkBytes+1))
	if err != nil || len(chunk) > protocol.SandboxMaximumFileChunkBytes || uint64(len(chunk)) > size-offset {
		return nil, 0, "", errors.New("download chunk is incomplete or exceeds its bounds")
	}
	hash := sha256.Sum256(chunk)
	if hex.EncodeToString(hash[:]) != digest {
		return nil, 0, "", errors.New("download chunk checksum failed; partial output discarded")
	}
	return chunk, size, version, nil
}
