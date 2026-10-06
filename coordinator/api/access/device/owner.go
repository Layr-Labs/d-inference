package device

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type Handler struct {
	store                 store.DeviceAuthStore
	logger                *slog.Logger
	consoleURL            string
	controlPlaneBodyBytes int64
}

func New(st store.DeviceAuthStore, logger *slog.Logger, consoleURL string, controlPlaneBodyBytes int64) *Handler {
	return &Handler{store: st, logger: logger, consoleURL: consoleURL, controlPlaneBodyBytes: controlPlaneBodyBytes}
}
