package testbed

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
)

func BuildOldProvider(ctx context.Context, logger *slog.Logger, r2CDNURL string, r2SitePackagesCDNURL string) (string, error) {
	repoRoot := FindRepoRoot()

	cacheDir := filepath.Join(repoRoot, ".cache", "e2e-binaries")
	binPath := filepath.Join(cacheDir, "darkbloom-"+OldCoordinatorTag)
	if _, err := os.Stat(binPath); err == nil {
		logger.Info("using cached old provider binary", "path", binPath)
		return binPath, nil
	}

	sourceDir := filepath.Join(cacheDir, "provider-src-"+OldCoordinatorTag)
	if _, err := os.Stat(filepath.Join(sourceDir, "provider")); os.IsNotExist(err) {
		if err := os.MkdirAll(sourceDir, 0755); err != nil {
			return "", fmt.Errorf("create provider source dir: %w", err)
		}
		for _, dir := range []string{"provider/", "enclave/"} {
			archiveCmd := exec.CommandContext(ctx, "git", "archive", OldCoordinatorTag, "--", dir)
			archiveCmd.Dir = repoRoot
			tarCmd := exec.CommandContext(ctx, "tar", "x", "-C", sourceDir)
			pr, pw, err := os.Pipe()
			if err != nil {
				return "", fmt.Errorf("pipe: %w", err)
			}
			archiveCmd.Stdout = pw
			tarCmd.Stdin = pr
			if err := archiveCmd.Start(); err != nil {
				return "", fmt.Errorf("git archive start %s: %w", dir, err)
			}
			if err := tarCmd.Start(); err != nil {
				return "", fmt.Errorf("tar start: %w", err)
			}
			if err := archiveCmd.Wait(); err != nil {
				return "", fmt.Errorf("git archive %s: %w", dir, err)
			}
			pw.Close()
			if err := tarCmd.Wait(); err != nil {
				return "", fmt.Errorf("tar extract %s: %w", dir, err)
			}
		}
	}

	logger.Info("building old provider binary", "tag", OldCoordinatorTag, "dir", sourceDir)

	origFn := filepath.Join(sourceDir, "provider", "src", "main.rs")
	mainRs, err := os.ReadFile(origFn)
	if err != nil {
		return "", fmt.Errorf("read main.rs for TeamID patch: %w", err)
	}
	patched := bytes.Replace(mainRs,
		[]byte(`.filter(|team| !team.is_empty() && *team != "not set")`),
		[]byte(`.filter(|team| !team.is_empty())`),
		1,
	)
	if bytes.Equal(patched, mainRs) {
		logger.Warn("TeamID patch did not apply — build may fail with ad-hoc signed binaries")
	} else {
		if err := os.WriteFile(origFn, patched, 0644); err != nil {
			return "", fmt.Errorf("write patched main.rs: %w", err)
		}
		logger.Info("patched v0.4.7 main.rs to accept ad-hoc TeamIdentifier")
	}

	buildCmd := exec.CommandContext(ctx, "cargo", "build", "--release", "--no-default-features")
	buildCmd.Dir = filepath.Join(sourceDir, "provider")
	buildCmd.Env = append(os.Environ(),
		"PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1",
		"DARKBLOOM_R2_CDN_URL="+r2CDNURL,
		"DARKBLOOM_R2_SITE_PACKAGES_CDN_URL="+r2SitePackagesCDNURL,
	)
	out, err := buildCmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cargo build old provider: %w: %s", err, string(out))
	}

	src := filepath.Join(sourceDir, "provider", "target", "release", "darkbloom")
	copyCmd := exec.CommandContext(ctx, "cp", src, binPath)
	if out, err := copyCmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("copy old provider binary: %w: %s", err, string(out))
	}

	logger.Info("old provider binary built", "path", binPath)
	return binPath, nil
}
