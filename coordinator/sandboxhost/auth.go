package sandboxhost

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/google/uuid"
)

const (
	HostIDHeader      = "X-Darkbloom-Sandbox-Host-ID"
	minimumTokenBytes = 32
	maximumTokenBytes = 256
)

type AuthConfig struct {
	TokenSHA256JSON string
}

func (c AuthConfig) Check() error {
	_, err := NewAuthenticator(c)
	return err
}

type Authenticator struct {
	tokenHashes map[string][sha256.Size]byte
}

func NewAuthenticator(config AuthConfig) (*Authenticator, error) {
	authenticator := &Authenticator{
		tokenHashes: make(map[string][sha256.Size]byte),
	}
	if strings.TrimSpace(config.TokenSHA256JSON) == "" {
		return authenticator, nil
	}
	encoded, err := decodeTokenHashes(config.TokenSHA256JSON)
	if err != nil {
		return nil, fmt.Errorf("decode sandbox host token hashes: %w", err)
	}
	if len(encoded) == 0 {
		return nil, errors.New("sandbox host token hash map must not be empty")
	}
	for hostID, encodedHash := range encoded {
		if !CanonicalHostID(hostID) {
			return nil, fmt.Errorf("invalid sandbox host ID %q", hostID)
		}
		rawHash, err := hex.DecodeString(encodedHash)
		if err != nil || len(rawHash) != sha256.Size {
			return nil, fmt.Errorf("invalid token hash for sandbox host %s", hostID)
		}
		var tokenHash [sha256.Size]byte
		copy(tokenHash[:], rawHash)
		authenticator.tokenHashes[strings.ToLower(hostID)] = tokenHash
	}
	return authenticator, nil
}

func decodeTokenHashes(raw string) (map[string]string, error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return nil, errors.New("sandbox host token hashes must be a JSON object")
	}
	encoded := make(map[string]string)
	seen := make(map[string]struct{})
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		hostID, ok := keyToken.(string)
		if !ok {
			return nil, errors.New("sandbox host token hash key is not a string")
		}
		normalized := strings.ToLower(hostID)
		if _, duplicate := seen[normalized]; duplicate {
			return nil, fmt.Errorf("duplicate sandbox host token hash for %s", hostID)
		}
		seen[normalized] = struct{}{}
		var encodedHash string
		if err := decoder.Decode(&encodedHash); err != nil {
			return nil, err
		}
		encoded[hostID] = encodedHash
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("sandbox host token hashes contain trailing JSON")
		}
		return nil, err
	}
	return encoded, nil
}

func (a *Authenticator) Enabled() bool {
	return a != nil && len(a.tokenHashes) > 0
}

func (a *Authenticator) Authenticate(hostID, token string) bool {
	if !a.Enabled() ||
		!CanonicalHostID(hostID) ||
		len(token) < minimumTokenBytes ||
		len(token) > maximumTokenBytes ||
		strings.TrimSpace(token) != token {
		return false
	}
	expected, exists := a.tokenHashes[strings.ToLower(hostID)]
	actual := sha256.Sum256([]byte(token))
	var zero [sha256.Size]byte
	if !exists {
		expected = zero
	}
	matches := subtle.ConstantTimeCompare(actual[:], expected[:]) == 1
	return exists && matches
}

func CanonicalHostID(value string) bool {
	if len(value) != 36 ||
		value[8] != '-' ||
		value[13] != '-' ||
		value[18] != '-' ||
		value[23] != '-' {
		return false
	}
	_, err := uuid.Parse(value)
	return err == nil
}
