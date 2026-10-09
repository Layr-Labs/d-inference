package autopilot

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type MachineController interface {
	ListMachineAutopilot(context.Context, string, int) ([]registry.MachineAutopilotStatus, error)
	SetMachineAutopilotDesiredMode(context.Context, string, store.MachineAutopilotMode) (registry.MachineAutopilotStatus, error)
}

// MachineHandler serves already-authorized requests; the registry owns both
// persisted intent and its runtime application.
type MachineHandler struct {
	Controller MachineController
}

func (h MachineHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPatch {
		machineID, valid := canonicalMachineID(r.PathValue("machine_id"))
		if !valid {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "machine_id must be a nonzero canonical UUID"))
			return
		}
		mode, err := decodeMachineDesiredMode(http.MaxBytesReader(w, r.Body, 1024))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		machine, err := h.Controller.SetMachineAutopilotDesiredMode(ctx, machineID, mode)
		if err != nil {
			writeMachineError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"machine": machine})
		return
	}

	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid query parameters"))
		return
	}
	var after string
	if values, present := query["after"]; present {
		var valid bool
		if len(values) == 1 {
			after, valid = canonicalMachineID(values[0])
		}
		if !valid {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "after must be a nonzero canonical UUID"))
			return
		}
	}
	limit := 100
	if values, present := query["limit"]; present {
		if len(values) != 1 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "limit must be an integer from 1 to 200"))
			return
		}
		limit, err = strconv.Atoi(values[0])
		if err != nil || limit < 1 || limit > 200 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "limit must be an integer from 1 to 200"))
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	machines, err := h.Controller.ListMachineAutopilot(ctx, after, limit)
	if err != nil {
		writeMachineError(w, err)
		return
	}
	if machines == nil {
		machines = []registry.MachineAutopilotStatus{}
	}
	response := map[string]any{"machines": machines}
	if len(machines) == limit {
		response["next_after"] = machines[len(machines)-1].MachineID
	}
	writeJSON(w, http.StatusOK, response)
}

func decodeMachineDesiredMode(body io.Reader) (store.MachineAutopilotMode, error) {
	decoder := json.NewDecoder(body)
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return "", errors.New("desired_mode is required")
	}
	// Reading the sole key explicitly also rejects duplicate keys and
	// case-insensitive field aliases accepted by struct decoding.
	field, err := decoder.Token()
	var mode store.MachineAutopilotMode
	if err != nil || field != "desired_mode" || decoder.Decode(&mode) != nil || (mode != store.MachineAutopilotShadow && mode != store.MachineAutopilotLive) {
		return "", errors.New("desired_mode must be shadow or live")
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') {
		return "", errors.New("only desired_mode is allowed")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return "", errors.New("exactly one JSON object is required")
	}
	return mode, nil
}

func canonicalMachineID(raw string) (string, bool) {
	id, err := uuid.Parse(raw)
	if err != nil || id == uuid.Nil || id.String() != strings.ToLower(raw) {
		return "", false
	}
	return id.String(), true
}

func writeMachineError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "machine not found"))
	case errors.Is(err, store.ErrInvalidMachineAutopilotMode):
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "desired_mode must be shadow or live"))
	default:
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("server_error", "machine Autopilot unavailable"))
	}
}
