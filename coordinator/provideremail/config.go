// Package provideremail builds provider-owner audiences for operator-reviewed
// Resend broadcasts. It never changes provider eligibility or sends a campaign.
package provideremail

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/mail"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/mod/semver"
)

type Campaign struct {
	ID               string  `json:"id"`
	Audience         string  `json:"audience"` // all, provider_update, macos_update
	MinimumVersion   string  `json:"minimum_version,omitempty"`
	ActiveWithinDays int     `json:"active_within_days"`
	OSMaxAgeDays     int     `json:"os_max_age_days"`
	Message          Message `json:"message"`
}

type Message struct {
	From            string `json:"from"`
	ReplyTo         string `json:"reply_to"`
	Subject         string `json:"subject"`
	Severity        string `json:"severity"`           // recommended or required
	Deadline        string `json:"deadline,omitempty"` // YYYY-MM-DD, displayed verbatim
	Body            string `json:"body"`
	InstructionsURL string `json:"instructions_url"`
	TopicID         string `json:"topic_id,omitempty"`
}

var campaignID = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,29}$`)
var numericVersion = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+){0,2}$`)

func DecodeCampaign(r io.Reader) (Campaign, error) {
	c := Campaign{ActiveWithinDays: 30, OSMaxAgeDays: 7}
	if err := decodeStrict(r, &c); err != nil {
		return c, fmt.Errorf("campaign JSON: %w", err)
	}
	return c, c.Validate()
}

func decodeStrict(r io.Reader, v any) error {
	d := json.NewDecoder(io.LimitReader(r, 8<<20))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return errors.New("expected exactly one JSON value")
	}
	return nil
}

func (c Campaign) Validate() error {
	if !campaignID.MatchString(c.ID) {
		return errors.New("id must be 1-30 lowercase letters, numbers or hyphens")
	}
	if c.ActiveWithinDays < 1 || c.ActiveWithinDays > 365 || c.OSMaxAgeDays < 1 || c.OSMaxAgeDays > 365 {
		return errors.New("active_within_days and os_max_age_days must be between 1 and 365")
	}
	switch c.Audience {
	case "all":
		if c.MinimumVersion != "" {
			return errors.New("all audience cannot have a minimum_version")
		}
	case "provider_update", "macos_update":
		if _, ok := version(c.MinimumVersion, c.Audience == "macos_update"); !ok {
			return errors.New("minimum_version must be an explicit valid version, never latest")
		}
	default:
		return errors.New("audience must be all, provider_update or macos_update")
	}
	if c.Message.Severity != "recommended" && c.Message.Severity != "required" {
		return errors.New("message.severity must be recommended or required")
	}
	if c.Message.Severity == "required" && c.Message.Deadline == "" {
		return errors.New("required notices need an explicit deadline")
	}
	if c.Message.Deadline != "" {
		if _, err := time.Parse(time.DateOnly, c.Message.Deadline); err != nil {
			return errors.New("message.deadline must be YYYY-MM-DD")
		}
	}
	for _, value := range []string{c.Message.From, c.Message.ReplyTo} {
		if strings.ContainsAny(value, "\r\n") {
			return errors.New("email headers cannot contain newlines")
		}
		if _, err := mail.ParseAddress(value); err != nil {
			return errors.New("message.from and message.reply_to must be email addresses")
		}
	}
	if strings.TrimSpace(c.Message.Subject) == "" || len(c.Message.Subject) > 200 || strings.ContainsAny(c.Message.Subject, "\r\n") {
		return errors.New("message.subject must be a single line of 1-200 characters")
	}
	if strings.TrimSpace(c.Message.Body) == "" || len(c.Message.Body) > 20000 {
		return errors.New("message.body must contain 1-20000 characters")
	}
	u, err := url.Parse(c.Message.InstructionsURL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return errors.New("message.instructions_url must be an HTTPS URL without credentials")
	}
	return nil
}

// SegmentName includes the audience policy so editing a version or window never
// silently repurposes a segment referenced by an older broadcast.
func (c Campaign) SegmentName() string {
	policy := fmt.Sprintf("%s\x00%s\x00%d\x00%d", c.Audience, c.MinimumVersion, c.ActiveWithinDays, c.OSMaxAgeDays)
	return "darkbloom/providers/" + c.ID + "/" + digest([]byte(policy))
}

func (c Campaign) DraftName() string {
	// Resend limits broadcast names to 70 characters. Hash the full campaign
	// instead of appending a second hash to the already named segment.
	raw, _ := json.Marshal(c)
	return "darkbloom/" + c.ID + "/" + digest(raw)
}

func digest(raw []byte) string {
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:8])
}

func version(s string, os bool) (string, bool) {
	s = strings.TrimSpace(s)
	if os {
		if !numericVersion.MatchString(s) {
			return "", false
		}
	} else {
		s = strings.TrimPrefix(s, "v")
	}
	v := "v" + s
	return v, semver.IsValid(v)
}

func normalizeEmail(s string) (string, bool) {
	s = strings.TrimSpace(s)
	a, err := mail.ParseAddress(s)
	if err != nil || a.Address != s || !strings.Contains(s, "@") || strings.ContainsAny(s, "\r\n") {
		return "", false
	}
	return strings.ToLower(s), true
}
