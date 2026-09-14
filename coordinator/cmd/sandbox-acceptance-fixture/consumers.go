package main

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func seedConsumer(backend seedStore, name string, expires time.Time) (string, string, error) {
	accountID := "sandbox-acceptance-" + uuid.NewString()
	user := &store.User{AccountID: accountID, PrivyUserID: "did:privy:fixture-" + uuid.NewString()}
	if err := backend.CreateUser(user); err != nil {
		return "", "", errors.New("could not create disposable consumer account")
	}
	key, _, err := backend.CreateAPIKey(accountID, store.APIKeyCreate{Name: name, ExpiresAt: &expires})
	if err != nil {
		return "", "", errors.New("could not mint disposable consumer API key")
	}
	return accountID, key, nil
}

func (p fixturePlan) allowedAccounts() string {
	if p.SecondaryAccountID != "" {
		return p.AccountID + "," + p.SecondaryAccountID
	}
	return p.AccountID
}

func consumerEnvironment(directory string, plan fixturePlan, secondary bool) (map[string]string, error) {
	name := "consumer-env.json"
	if secondary {
		if plan.SchemaVersion != 2 || plan.SecondaryAccountID == "" || plan.SecondaryAccountID == plan.AccountID {
			return nil, errors.New("second-account launch requires a new two-consumer fixture")
		}
		name = "secondary-consumer-env.json"
	}
	data, err := readPrivate(filepath.Join(directory, name), 4096)
	if err != nil {
		return nil, err
	}
	var consumer map[string]string
	if json.Unmarshal(data, &consumer) != nil || len(consumer) != 2 || consumer["DARKBLOOM_API_URL"] != plan.APIURL ||
		consumer["DARKBLOOM_API_KEY"] == "" || strings.IndexFunc(consumer["DARKBLOOM_API_KEY"], unicode.IsSpace) >= 0 {
		return nil, errors.New("invalid isolated consumer environment")
	}
	if secondary {
		primary, err := consumerEnvironment(directory, plan, false)
		if err != nil {
			return nil, err
		}
		if consumer["DARKBLOOM_API_KEY"] == primary["DARKBLOOM_API_KEY"] {
			return nil, errors.New("acceptance requires distinct consumer credentials")
		}
	}
	return consumer, nil
}
