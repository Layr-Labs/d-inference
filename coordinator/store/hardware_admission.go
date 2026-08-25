package store

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
)

var ErrHardwareAdmissionPolicyConflict = errors.New("hardware admission policy version conflict")
var ErrHardwareAdmissionRevoked = errors.New("hardware admission revoked")

type HardwareAdmission struct {
	SerialNumber     string                     `json:"serial_number"`
	Source           string                     `json:"source"`
	PolicyVersion    int64                      `json:"policy_version"`
	Hardware         hardwareadmission.Observed `json:"hardware"`
	AdmittedAt       time.Time                  `json:"admitted_at"`
	RevokedAt        *time.Time                 `json:"revoked_at,omitempty"`
	RevokedBy        string                     `json:"revoked_by,omitempty"`
	RevocationReason string                     `json:"revocation_reason,omitempty"`
}

type HardwareAdmissionAttempt struct {
	ID            int64                       `json:"id"`
	ProviderID    string                      `json:"provider_id"`
	SerialNumber  string                      `json:"serial_number,omitempty"`
	AccountID     string                      `json:"account_id,omitempty"`
	PolicyVersion int64                       `json:"policy_version"`
	Mode          hardwareadmission.Mode      `json:"mode"`
	Decision      string                      `json:"decision"`
	ReasonCode    string                      `json:"reason_code,omitempty"`
	Hardware      hardwareadmission.Observed  `json:"hardware"`
	FailedChecks  []hardwareadmission.Failure `json:"failed_checks,omitempty"`
	CreatedAt     time.Time                   `json:"created_at"`
}

func (a HardwareAdmissionAttempt) hardwareJSON() json.RawMessage {
	raw, _ := json.Marshal(a.Hardware)
	return raw
}

func (a HardwareAdmissionAttempt) failedChecksJSON() json.RawMessage {
	raw, _ := json.Marshal(a.FailedChecks)
	return raw
}

func normalizeHardwareSerial(serial string) string {
	return strings.ToUpper(strings.TrimSpace(serial))
}
