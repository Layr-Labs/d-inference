package provideremail

import (
	"errors"
	"io"
	"sort"
	"time"

	"golang.org/x/mod/semver"
)

type Machine struct {
	ID              string    `json:"machine_id"`
	AccountID       string    `json:"account_id"`
	Email           string    `json:"email"`
	Source          string    `json:"source"`
	LastSeen        time.Time `json:"last_seen"`
	ProviderVersion string    `json:"provider_version"`
	OSVersion       string    `json:"os_version"`
	OSSource        string    `json:"os_source"`
	OSObservedAt    time.Time `json:"os_observed_at"`
}

type Snapshot struct {
	CapturedAt        time.Time `json:"captured_at"`
	UntrackedSessions int       `json:"untracked_sessions"`
	Machines          []Machine `json:"machines"`
}

type Recipient struct {
	Email            string   `json:"email"`
	AccountIDs       []string `json:"account_ids"`
	AffectedMachines int      `json:"affected_machines"`
}

type Counts struct {
	Machines          int `json:"machines"`
	Inactive          int `json:"inactive"`
	UnknownOwner      int `json:"unknown_owner"`
	Historical        int `json:"historical"`
	UnknownVersion    int `json:"unknown_version"`
	AtTarget          int `json:"at_target"`
	NeedsUpdate       int `json:"needs_update"`
	MissingEmail      int `json:"missing_email"`
	Recipients        int `json:"recipients"`
	UntrackedSessions int `json:"untracked_sessions"`
}

type Audience struct {
	CapturedAt time.Time   `json:"captured_at"`
	CampaignID string      `json:"campaign_id"`
	Segment    string      `json:"segment"`
	Counts     Counts      `json:"counts"`
	Recipients []Recipient `json:"recipients"`
}

func DecodeSnapshot(r io.Reader) (Snapshot, error) {
	var s Snapshot
	err := decodeStrict(r, &s)
	return s, err
}

func BuildAudience(c Campaign, s Snapshot, now time.Time) (Audience, error) {
	a := Audience{CapturedAt: s.CapturedAt, CampaignID: c.ID, Segment: c.SegmentName(), Recipients: []Recipient{}}
	if err := c.Validate(); err != nil {
		return a, err
	}
	if s.CapturedAt.IsZero() || s.CapturedAt.After(now.Add(time.Minute)) || now.Sub(s.CapturedAt) > 15*time.Minute {
		return a, errors.New("snapshot must have been captured within the last 15 minutes")
	}
	a.Counts.UntrackedSessions = s.UntrackedSessions
	seen := make(map[string]bool)
	recipients := make(map[string]*Recipient)
	target, _ := version(c.MinimumVersion, c.Audience == "macos_update")
	for _, m := range s.Machines {
		if m.ID == "" || seen[m.ID] {
			return a, errors.New("snapshot contains missing or duplicate machine IDs")
		}
		seen[m.ID] = true
		a.Counts.Machines++
		if m.LastSeen.IsZero() || m.LastSeen.After(s.CapturedAt.Add(time.Minute)) || m.LastSeen.Before(s.CapturedAt.AddDate(0, 0, -c.ActiveWithinDays)) {
			a.Counts.Inactive++
			continue
		}
		if m.Source != "live_registration" {
			a.Counts.Historical++
			continue
		}
		if m.AccountID == "" {
			a.Counts.UnknownOwner++
			continue
		}
		if c.Audience != "all" {
			raw := m.ProviderVersion
			if c.Audience == "macos_update" {
				raw = m.OSVersion
				if m.OSSource != "registration_report" && m.OSSource != "app_attest_assertion_report" || m.OSObservedAt.IsZero() || m.OSObservedAt.After(s.CapturedAt.Add(time.Minute)) || m.OSObservedAt.Before(s.CapturedAt.AddDate(0, 0, -c.OSMaxAgeDays)) {
					raw = ""
				}
			}
			v, ok := version(raw, c.Audience == "macos_update")
			if !ok {
				a.Counts.UnknownVersion++
				continue
			}
			if semver.Compare(v, target) >= 0 {
				a.Counts.AtTarget++
				continue
			}
			a.Counts.NeedsUpdate++
		}
		email, ok := normalizeEmail(m.Email)
		if !ok {
			a.Counts.MissingEmail++
			continue
		}
		r := recipients[email]
		if r == nil {
			r = &Recipient{Email: email}
			recipients[email] = r
		}
		r.AffectedMachines++
		found := false
		for _, id := range r.AccountIDs {
			found = found || id == m.AccountID
		}
		if !found {
			r.AccountIDs = append(r.AccountIDs, m.AccountID)
		}
	}
	for _, r := range recipients {
		sort.Strings(r.AccountIDs)
		a.Recipients = append(a.Recipients, *r)
	}
	sort.Slice(a.Recipients, func(i, j int) bool { return a.Recipients[i].Email < a.Recipients[j].Email })
	a.Counts.Recipients = len(a.Recipients)
	return a, nil
}
