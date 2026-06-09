package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/stateexport"
)

// State-export env vars (all namespaced under env.EnvPrefix == "EIGENINFERENCE").
const (
	// envStateExportEnabled is the master switch. When != "true" the route 404s.
	envStateExportEnabled = env.EnvPrefix + "_STATE_EXPORT_ENABLED"
	// envStateExportRecipient is an age recipient ("age1..."). When set, output is
	// encrypted to it; this is the default-secure path.
	envStateExportRecipient = env.EnvPrefix + "_STATE_EXPORT_RECIPIENT"
	// envStateExportAllowPlaintext permits a raw (unencrypted) zip ONLY when no
	// recipient is configured. Must be explicitly "true".
	envStateExportAllowPlaintext = env.EnvPrefix + "_STATE_EXPORT_ALLOW_PLAINTEXT"
	// envStateExportRoot overrides the export root (primarily for tests).
	envStateExportRoot = env.EnvPrefix + "_STATE_EXPORT_ROOT"
)

// resolveStateExportRoot picks the directory to archive:
// EIGENINFERENCE_STATE_EXPORT_ROOT -> USER_PERSISTENT_DATA_PATH -> /mnt/disks/userdata.
func resolveStateExportRoot() string {
	return env.FirstNonEmpty(
		os.Getenv(envStateExportRoot),
		os.Getenv("USER_PERSISTENT_DATA_PATH"),
		"/mnt/disks/userdata",
	)
}

// envTrue reports whether the named env var is set to "true" (case-insensitive,
// trimmed). Used for the boolean state-export gates.
func envTrue(name string) bool {
	b, _ := strconv.ParseBool(strings.TrimSpace(os.Getenv(name)))
	return b
}

// handleAdminStateExport handles GET /v1/admin/state-export — it streams a
// consistent (and, by default, encrypted) archive of the coordinator's sealed
// on-disk state under /data for migration off EigenCloud (DAR-70).
//
// Triple gate, fail-closed, in order:
//  1. master switch (404 when off — route stays invisible/inert),
//  2. admin auth (admin-key only; Privy admin is intentionally NOT accepted),
//  3. output protection (encrypt to recipient, else 412 unless plaintext allowed).
func (s *Server) handleAdminStateExport(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// (a) Master switch — 404 when disabled so the route is indistinguishable
	// from an unregistered path.
	if !envTrue(envStateExportEnabled) {
		http.NotFound(w, r)
		return
	}

	// (b) Admin auth — ADMIN KEY ONLY (constant-time), modeled on
	// requireAdminKey's bearer-token check. This endpoint exfils the CA private
	// key, so we deliberately do NOT accept the Privy-admin path: a compromised
	// Privy admin email must not be able to pull the CA key. (The route is also
	// not wrapped in Privy auth middleware, so auth.UserFromContext is nil here
	// regardless.)
	token := extractBearerToken(r)
	// Hash both sides to a fixed 32 bytes before the constant-time compare so the
	// check leaks neither the admin key's contents nor its length. (A bare
	// ConstantTimeCompare returns early when the two byte slices differ in
	// length — a minor timing side-channel on key length. This is the CA-key
	// exfil endpoint, so close it.)
	providedDigest := sha256.Sum256([]byte(token))
	expectedDigest := sha256.Sum256([]byte(s.adminKey))
	if s.adminKey == "" || subtle.ConstantTimeCompare(providedDigest[:], expectedDigest[:]) != 1 {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
		s.logger.Warn("state-export: unauthorized access attempt",
			"remote_addr", r.RemoteAddr, "authorized", false)
		return
	}

	// (c) Output protection. Encrypted by default.
	recipientStr := strings.TrimSpace(os.Getenv(envStateExportRecipient))
	allowPlaintext := envTrue(envStateExportAllowPlaintext)
	encrypted := recipientStr != ""

	if !encrypted && !allowPlaintext {
		writeJSON(w, http.StatusPreconditionFailed, errorResponse("precondition_failed",
			"set "+envStateExportRecipient+" to an age recipient, or set "+
				envStateExportAllowPlaintext+"=true to download unencrypted"))
		s.logger.Warn("state-export: refused (no recipient, plaintext not allowed)",
			"remote_addr", r.RemoteAddr, "authorized", true, "encrypted", false)
		return
	}

	// Stage (below) resolves (EvalSymlinks) + stats the root and returns a clean
	// error mapped to a pre-stream 500, so no separate os.Stat pre-check here.
	root := resolveStateExportRoot()

	// Compute the download filename / content-type BEFORE writing headers.
	epoch := strconv.FormatInt(time.Now().Unix(), 10)
	var filename, contentType string
	if encrypted {
		filename = "darkbloom-state-" + epoch + ".zip.age"
		contentType = "application/octet-stream"
	} else {
		filename = "darkbloom-state-" + epoch + ".zip"
		contentType = "application/zip"
	}

	// Validate the recipient up front (before any header is written) so a parse
	// failure is a clean 500 rather than a half-written stream.
	if encrypted {
		if err := stateexport.ValidateRecipient(recipientStr); err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("export_error",
				"state export recipient is misconfigured"))
			// Do not log the recipient material; log only that parsing failed.
			s.logger.Error("state-export: recipient parse failed",
				"remote_addr", r.RemoteAddr, "authorized", true, "encrypted", true)
			return
		}
	}

	// PHASE A — snapshot+validate every *.db into a controlled staging dir BEFORE
	// writing any response status/bytes. Any failure here is fail-clean: we emit a
	// real 500 and the client gets ZERO archive bytes. This is what closes the
	// "partial archive after 200" + "/tmp leak" findings: copies live in one
	// staging dir we always RemoveAll, and a torn db that can't snapshot aborts
	// the whole export up front.
	arch := stateexport.NewArchiver()
	arch.Logger = s.logger
	// Propagate the request context (no artificial deadline — a legit large
	// export must not be truncated by a timer) so a client disconnect cancels the
	// snapshot/walk cleanly.
	staged, stageErr := arch.Stage(r.Context(), root)
	if stageErr != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("export_error",
			"state export could not produce a consistent snapshot"))
		s.logger.Error("state-export: staging failed (no bytes written)",
			"remote_addr", r.RemoteAddr, "authorized", true, "encrypted", encrypted,
			"root", root, "error", stageErr.Error())
		return
	}
	// Always release the staging dir + validated db copies, even on a mid-stream
	// failure or panic.
	defer staged.Cleanup()

	// PHASE B — only now commit to a 200 and stream the zip.
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	w.WriteHeader(http.StatusOK)

	// Writer chain (streamed, never buffered):
	//   archiver -> [age encrypt] -> countingWriter -> http.ResponseWriter
	// The counter wraps the response so it tallies the actual bytes sent to the
	// client (ciphertext when encrypted).
	counter := &countingWriter{w: w}

	var sink io.Writer = counter
	var ageWriter io.WriteCloser
	if encrypted {
		aw, err := stateexport.EncryptWriter(counter, recipientStr)
		if err != nil {
			// Headers already sent; we can only abort the stream.
			s.logger.Error("state-export: age writer init failed after headers",
				"remote_addr", r.RemoteAddr, "error", err.Error())
			return
		}
		ageWriter = aw
		sink = aw
	}

	res, archErr := arch.Write(r.Context(), staged, sink)

	// For encrypted streams, MUST close the age writer to flush the final chunk.
	if ageWriter != nil {
		if cerr := ageWriter.Close(); cerr != nil && archErr == nil {
			archErr = cerr
		}
	}

	if archErr != nil {
		// Headers/body already in flight — cannot change status. Log the failure;
		// the truncated stream signals the error to the client.
		s.logger.Error("state-export: archive failed mid-stream",
			"remote_addr", r.RemoteAddr, "authorized", true, "encrypted", encrypted,
			"bytes", counter.n, "files", res.Files, "error", archErr.Error())
		return
	}

	s.logger.Info("state-export: completed",
		"remote_addr", r.RemoteAddr,
		"authorized", true,
		"encrypted", encrypted,
		"files", res.Files,
		"snapshotted_dbs", res.SnapshottedDBs,
		"bytes", counter.n,
		"duration_ms", time.Since(start).Milliseconds(),
		"outcome", "ok",
	)
}

// countingWriter tallies bytes written for the audit log without buffering.
type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}
