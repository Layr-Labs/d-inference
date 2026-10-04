package process

import (
	"path/filepath"

	artifacts "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/artifacts"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
)

const MaxSupervisorReasonBytes = 512

func PrepareSocketDirectory(socketPath string) error {
	directory := filepath.Dir(socketPath)
	opened, err := artifacts.SecureOpenAbsoluteDirectory(directory, true, 0o700)
	if err != nil {
		return err
	}
	defer opened.Close()
	info, err := opened.Stat()
	if err != nil || !info.IsDir() {
		return catalog.ErrInvalidConfig
	}
	return opened.Chmod(0o700)
}
