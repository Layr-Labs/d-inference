package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type fixturePlan struct {
	SchemaVersion int       `json:"schema_version"`
	Status        string    `json:"status"`
	AccountID     string    `json:"account_id"`
	HostID        string    `json:"host_id"`
	APIURL        string    `json:"api_url"`
	HostURL       string    `json:"host_websocket_url"`
	BaseImage     string    `json:"base_image_id"`
	Coordinator   string    `json:"coordinator_binary"`
	Client        string    `json:"client_binary"`
	KeyExpiresAt  time.Time `json:"consumer_key_expires_at"`
}

func readPrivate(name string, limit int64) ([]byte, error) {
	if !filepath.IsAbs(name) {
		return nil, errors.New("credential/config path must be absolute")
	}
	descriptor, err := syscall.Open(name, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, errors.New("cannot open private credential/config file")
	}
	file := os.NewFile(uintptr(descriptor), name)
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > limit {
		return nil, errors.New("credential/config file must be bounded, regular and owner-only")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Geteuid()) {
		return nil, errors.New("credential/config file must belong to the current user")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("cannot read bounded credential/config file")
	}
	return data, nil
}

func writePrivate(name string, data []byte) error {
	file, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("fixture output already exists or is unwritable")
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return errors.New("could not write private fixture output")
	}
	if err := file.Sync(); err != nil {
		return errors.New("could not persist private fixture output")
	}
	directory, err := os.Open(filepath.Dir(name))
	if err != nil {
		return errors.New("could not open fixture directory for persistence")
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return errors.New("could not persist fixture directory")
	}
	return nil
}

func writePrivateJSON(name string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return errors.New("cannot encode fixture configuration")
	}
	return writePrivate(name, append(data, '\n'))
}

func loadPlan(directory string) (fixturePlan, error) {
	var plan fixturePlan
	data, err := readPrivate(filepath.Join(directory, "fixture.json"), 16384)
	if err != nil {
		return plan, err
	}
	if json.Unmarshal(data, &plan) != nil || plan.SchemaVersion != 1 || plan.Status != "seeded" {
		return plan, errors.New("fixture is incomplete or invalid")
	}
	return plan, nil
}
