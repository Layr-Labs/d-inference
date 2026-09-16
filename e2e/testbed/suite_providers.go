package testbed

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Suite) startProviders() error {
	providerURL := s.Coordinator.BaseURL()
	if s.Config.ProviderRelay != nil {
		providerURL = s.Config.ProviderRelay.Start(providerURL)
	}
	var binaryPath string
	if s.Config.ProviderTargets == nil {
		var err error
		binaryPath, err = BuildProvider(s.Ctx, s.Logger)
		if err != nil {
			return fmt.Errorf("build provider: %w", err)
		}
	}

	providerIdx := 0
	for _, spec := range s.Config.ModelSpecs {
		modelIDs := spec.IDs()
		for j := 0; j < spec.NumProviders; j++ {
			if providerIdx > 0 {
				time.Sleep(500 * time.Millisecond)
			}
			p := &Provider{
				BinaryPath:    binaryPath,
				Logger:        s.Logger.With("provider_index", providerIdx, "models", strings.Join(modelIDs, ",")),
				ProviderIndex: providerIdx,
			}
			authDir, authTokenPath, err := s.prepareProviderAuth(providerIdx)
			if err != nil {
				return fmt.Errorf("prepare provider auth %d: %w", providerIdx, err)
			}
			p.AuthDir = authDir
			p.AccountID = fmt.Sprintf("testbed-provider-%d", providerIdx)
			if s.Config.ProviderTargets != nil {
				target := s.Config.ProviderTargets[providerIdx]
				p.Target = &target
				p.suiteNonce = s.targetNonce
			}
			if p.Target != nil {
				s.providerAttempts = append(s.providerAttempts, p)
			}
			if err := p.Start(s.Ctx, providerURL, ProviderConfig{
				ModelIDs:                   modelIDs,
				PrefixCacheMode:            s.Config.PrefixCacheMode,
				TrustLevel:                 TrustNone,
				MTPDrafterPath:             s.Config.MTPDrafterPath,
				MTPMode:                    s.Config.MTPMode,
				AuthTokenPath:              authTokenPath,
				EnableEphemeralPrefixCache: s.Config.EnableEphemeralPrefixCache,
				KVBackend:                  s.Config.KVBackend,
				MaxConcurrent:              s.Config.MaxConcurrent,
			}); err != nil {
				cleanupErr := p.StopAndWait()
				if cleanupErr == nil {
					_ = os.RemoveAll(authDir)
				}
				return errors.Join(fmt.Errorf("start provider %d (%s): %w", providerIdx, strings.Join(modelIDs, ","), err), cleanupErr)
			}
			s.Providers = append(s.Providers, p)
			providerIdx++
		}
	}
	return nil
}

func (s *Suite) prepareProviderAuth(providerIdx int) (string, string, error) {
	rawToken := fmt.Sprintf("testbed-provider-token-%d-%d", providerIdx, time.Now().UnixNano())
	tokenHash := sha256.Sum256([]byte(rawToken))
	accountID := fmt.Sprintf("testbed-provider-%d", providerIdx)
	if err := s.PgStore.CreateProviderToken(&store.ProviderToken{
		TokenHash: hex.EncodeToString(tokenHash[:]),
		AccountID: accountID,
		Label:     fmt.Sprintf("testbed-provider-%d", providerIdx),
		Active:    true,
		CreatedAt: time.Now(),
	}); err != nil {
		return "", "", err
	}

	authDir, err := os.MkdirTemp("", fmt.Sprintf("darkbloom-testbed-provider-%d-", providerIdx))
	if err != nil {
		return "", "", err
	}
	tokenDir := filepath.Join(authDir, ".darkbloom")
	if err := os.MkdirAll(tokenDir, 0700); err != nil {
		_ = os.RemoveAll(authDir)
		return "", "", err
	}
	authTokenPath := filepath.Join(tokenDir, "auth_token")
	if err := os.WriteFile(authTokenPath, []byte(rawToken+"\n"), 0600); err != nil {
		_ = os.RemoveAll(authDir)
		return "", "", err
	}
	return authDir, authTokenPath, nil
}
