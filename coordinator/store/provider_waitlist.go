package store

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// ProviderWaitlistSignup records an unverified hardware-interest submission.
// It does not authorize notifications or prove ownership of the email address.
type ProviderWaitlistSignup struct {
	Email        string `json:"email"`
	Chip         string `json:"chip"`
	MemoryGB     int    `json:"memory_gb"`
	GPUCores     int    `json:"gpu_cores,omitempty"`
	OtherMachine string `json:"other_machine,omitempty"`
	// SubmittedAt records an unverified public form submission. It is not
	// proof that the submitter owns Email and must not authorize outbound mail.
	SubmittedAt time.Time `json:"submitted_at"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// ProviderWaitlistStore persists hardware-interest submissions independently
// from user accounts: rejected machines may not have completed account linking.
type ProviderWaitlistStore interface {
	UpsertProviderWaitlistSignup(context.Context, ProviderWaitlistSignup) error
	ListProviderWaitlistSignups(context.Context, int) ([]ProviderWaitlistSignup, error)
}

func normalizeProviderWaitlistEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func normalizeAndValidateProviderWaitlistSignup(
	signup *ProviderWaitlistSignup,
) error {
	signup.Email = normalizeProviderWaitlistEmail(signup.Email)
	signup.Chip = strings.TrimSpace(signup.Chip)
	signup.OtherMachine = strings.TrimSpace(signup.OtherMachine)
	if signup.Email == "" {
		return fmt.Errorf("provider waitlist email is required")
	}
	if signup.Chip == "" {
		return fmt.Errorf("provider waitlist chip is required")
	}
	if signup.MemoryGB < 4 || signup.MemoryGB > 1024 {
		return fmt.Errorf("provider waitlist memory_gb must be between 4 and 1024")
	}
	if signup.GPUCores < 0 || signup.GPUCores > 512 {
		return fmt.Errorf("provider waitlist gpu_cores must be between 0 and 512")
	}
	return nil
}

func providerWaitlistListLimit(limit int) int {
	if limit <= 0 {
		return 100
	}
	if limit > 1000 {
		return 1000
	}
	return limit
}
