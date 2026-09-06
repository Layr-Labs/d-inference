package testbed

import (
	"fmt"
	"math"
	"path/filepath"
	"regexp"
	"strings"
)

// ProviderFile pins a regular file on the selected host. Paths are relative to
// their declared directory; the helper checks bytes, mode and SHA before launch.
type ProviderFile struct {
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
	Mode   uint32 `json:"mode"`
}

type ProviderModelInput struct {
	ID       string                  `json:"id"`
	Snapshot string                  `json:"snapshot"`
	Files    map[string]ProviderFile `json:"files"`
}

type ProviderSSH struct {
	Destination  string `json:"destination"`
	IdentityFile string `json:"identity_file"`
	Python       string `json:"python"`
	ForwardPort  int    `json:"forward_port"`
}

// ProviderTarget is an opt-in owned fixture host, not a serving configuration.
// Runtime files and model snapshots must already exist on that host. The helper
// copies only the selected runtime into Root and does not download/repair models.
type ProviderTarget struct {
	Name                  string                  `json:"name"`
	Root                  string                  `json:"root"`
	RuntimeDirectory      string                  `json:"runtime_directory"`
	RuntimeFiles          map[string]ProviderFile `json:"runtime_files"`
	Models                []ProviderModelInput    `json:"models"`
	AssistantPath         string                  `json:"assistant_path,omitempty"`
	CanonicalConfigSHA256 string                  `json:"canonical_config_sha256"`
	HardwareModel         string                  `json:"hardware_model"`
	MemoryBytes           uint64                  `json:"memory_bytes"`
	MacmonPath            string                  `json:"macmon_path"`
	Macmon                ProviderFile            `json:"macmon"`
	SSH                   *ProviderSSH            `json:"ssh,omitempty"`
}

var targetName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,47}$`)
var hash256 = regexp.MustCompile(`^[0-9a-f]{64}$`)
var sshDestination = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$`)

func cleanAbsolute(path string) bool {
	return filepath.IsAbs(path) && filepath.Clean(path) == path && path != "/" && !strings.ContainsAny(path, "\x00\r\n")
}
func validateProviderFiles(files map[string]ProviderFile) error {
	if len(files) == 0 || len(files) > 2048 {
		return fmt.Errorf("explicit bounded file manifest required")
	}
	for name, row := range files {
		if !filepath.IsLocal(name) || filepath.Clean(name) != name || strings.ContainsAny(name, "\x00\r\n") || !hash256.MatchString(row.SHA256) || row.Bytes < 0 || row.Mode > 0777 {
			return fmt.Errorf("invalid file manifest entry %q", name)
		}
	}
	return nil
}
func (t ProviderTarget) validate() error {
	if !targetName.MatchString(t.Name) || !cleanAbsolute(t.Root) || !cleanAbsolute(t.RuntimeDirectory) || t.Root == t.RuntimeDirectory {
		return fmt.Errorf("invalid owned target identity or root")
	}
	if !hash256.MatchString(t.CanonicalConfigSHA256) || t.HardwareModel == "" || t.MemoryBytes == 0 || !cleanAbsolute(t.MacmonPath) {
		return fmt.Errorf("host identity and preflight inputs required")
	}
	if err := validateProviderFiles(t.RuntimeFiles); err != nil {
		return err
	}
	if file, ok := t.RuntimeFiles["darkbloom"]; !ok || file.Mode != 0755 {
		return fmt.Errorf("runtime needs exact executable darkbloom")
	}
	if _, ok := t.RuntimeFiles["mlx.metallib"]; !ok {
		return fmt.Errorf("runtime needs exact mlx.metallib")
	}
	for name := range t.RuntimeFiles {
		if name != "darkbloom" && name != "mlx.metallib" && !strings.HasSuffix(strings.SplitN(name, "/", 2)[0], ".bundle") {
			return fmt.Errorf("non-runtime file in runtime manifest")
		}
	}
	if err := validateProviderFiles(map[string]ProviderFile{"macmon": t.Macmon}); err != nil {
		return err
	}
	if t.Macmon.Mode&0111 == 0 {
		return fmt.Errorf("macmon must be executable")
	}
	if len(t.Models) == 0 || len(t.Models) > 8 {
		return fmt.Errorf("explicit model inputs required")
	}
	ids := map[string]bool{}
	for _, m := range t.Models {
		if m.ID == "" || strings.Contains(m.ID, "..") || strings.ContainsAny(m.ID, "\x00\r\n") || ids[m.ID] || !cleanAbsolute(m.Snapshot) {
			return fmt.Errorf("invalid or duplicate model input")
		}
		ids[m.ID] = true
		if err := validateProviderFiles(m.Files); err != nil {
			return err
		}
	}
	if t.AssistantPath != "" {
		if !cleanAbsolute(t.AssistantPath) {
			return fmt.Errorf("invalid assistant path")
		}
		matched := false
		for _, model := range t.Models {
			if model.Snapshot == t.AssistantPath {
				matched = true
			}
		}
		if !matched {
			return fmt.Errorf("assistant path is not bound to a model manifest")
		}
	}
	if t.SSH != nil {
		if !sshDestination.MatchString(t.SSH.Destination) || !cleanAbsolute(t.SSH.IdentityFile) || !cleanAbsolute(t.SSH.Python) || t.SSH.ForwardPort < 1024 || t.SSH.ForwardPort > 65535 {
			return fmt.Errorf("invalid typed SSH target")
		}
	}
	return nil
}

func validateProviderTargets(targets []ProviderTarget, total int) error {
	if targets == nil {
		return nil
	}
	if len(targets) != total || total == 0 {
		return fmt.Errorf("provider target count must equal requested providers")
	}
	names, roots, ports := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, t := range targets {
		if err := t.validate(); err != nil {
			return fmt.Errorf("target %q: %w", t.Name, err)
		}
		host := "local"
		if t.SSH != nil {
			host = t.SSH.Destination
			key := fmt.Sprintf("%s:%d", host, t.SSH.ForwardPort)
			if ports[key] {
				return fmt.Errorf("duplicate SSH forwarding port")
			}
			ports[key] = true
		}
		key := host + ":" + t.Root
		if names[t.Name] || roots[key] {
			return fmt.Errorf("duplicate provider target name or owned root")
		}
		names[t.Name] = true
		roots[key] = true
	}
	return nil
}

// HostObservation records facts separately from the decisions made about them.
// Hot post-work telemetry never changes the outcome of a completed request.
type HostObservation struct {
	HardwareModel       string  `json:"hardware_model"`
	MemoryBytes         uint64  `json:"memory_bytes"`
	GPUTemperature      float64 `json:"gpu_temperature_c"`
	Load1               float64 `json:"load1"`
	FreeBytes           uint64  `json:"free_bytes"`
	UnexpectedProcesses []int   `json:"unexpected_processes"`
	OwnedProcesses      []int   `json:"owned_processes"`
}

func (o HostObservation) EntryReady() error {
	if len(o.UnexpectedProcesses) > 0 {
		return fmt.Errorf("unexpected host processes")
	}
	if math.IsNaN(o.GPUTemperature) || math.IsInf(o.GPUTemperature, 0) || o.GPUTemperature < 0 || o.GPUTemperature > 42 || math.IsNaN(o.Load1) || math.IsInf(o.Load1, 0) || o.Load1 < 0 || o.Load1 > 4 || o.FreeBytes <= 100*(1<<30) {
		return fmt.Errorf("host not ready for measured entry")
	}
	return nil
}
func (o HostObservation) CleanupComplete() error {
	if len(o.UnexpectedProcesses) > 0 || len(o.OwnedProcesses) > 0 {
		return fmt.Errorf("host has process leftovers")
	}
	return nil
}

// ValidateProviderTargets is pure; remote manifests are checked on their host
// before any owned root/config/runtime/provider work.
func ValidateProviderTargets(targets []ProviderTarget, total int) error {
	return validateProviderTargets(targets, total)
}
