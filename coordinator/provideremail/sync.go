package provideremail

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail/resend"
)

type AudienceAPI interface {
	Segments(context.Context) ([]resend.Segment, error)
	Contacts(context.Context) ([]resend.Contact, error)
	Members(context.Context, string) ([]resend.Contact, error)
	Broadcasts(context.Context) ([]resend.Broadcast, error)
	CreateSegment(context.Context, string) (string, error)
	CreateContact(context.Context, string) (string, error)
	AddMember(context.Context, string, string) error
	RemoveMember(context.Context, string, string) error
	CreateDraft(context.Context, resend.Draft) (string, error)
}

type SyncResult struct {
	SegmentID    string `json:"segment_id,omitempty"`
	Create       int    `json:"contacts_to_create"`
	Add          int    `json:"members_to_add"`
	Remove       int    `json:"members_to_remove"`
	Unsubscribed int    `json:"unsubscribed_recipients"`
	Applied      bool   `json:"applied"`
}

// Sync reconciles only this policy's segment. It never deletes contacts or
// changes subscription preferences. Removals precede additions. Any error
// stops the operation and prevents subsequent draft creation.
func Sync(ctx context.Context, api AudienceAPI, c Campaign, a Audience, apply bool) (SyncResult, error) {
	var result SyncResult
	if err := c.Validate(); err != nil {
		return result, err
	}
	if a.Segment != c.SegmentName() || a.CampaignID != c.ID {
		return result, errors.New("audience does not match the campaign policy")
	}
	if err := checkAudienceAge(a); err != nil {
		return result, err
	}
	segments, err := api.Segments(ctx)
	if err != nil {
		return result, err
	}
	for _, s := range segments {
		if s.Name == a.Segment {
			if result.SegmentID != "" {
				return result, errors.New("duplicate managed segment names; resolve in Resend before syncing")
			}
			result.SegmentID = s.ID
		}
	}
	// Do not change an audience being sent or scheduled. A sent broadcast can
	// share the segment with a new reminder draft; its historical recipients
	// remain in Resend's delivery record.
	if result.SegmentID != "" {
		broadcasts, err := api.Broadcasts(ctx)
		if err != nil {
			return result, err
		}
		for _, b := range broadcasts {
			if b.SegmentID == result.SegmentID && b.Status != "draft" && b.Status != "sent" && b.Status != "canceled" {
				return result, errors.New("managed segment has an active or unknown-status broadcast; cancel or finish it before syncing")
			}
		}
	}
	contacts, err := api.Contacts(ctx)
	if err != nil {
		return result, err
	}
	byEmail := make(map[string]resend.Contact)
	for _, contact := range contacts {
		email, ok := normalizeEmail(contact.Email)
		if !ok {
			continue
		}
		if _, exists := byEmail[email]; exists {
			return result, errors.New("ambiguous duplicate contact email in Resend")
		}
		byEmail[email] = contact
	}
	var members []resend.Contact
	if result.SegmentID != "" {
		members, err = api.Members(ctx, result.SegmentID)
		if err != nil {
			return result, err
		}
	}
	want := make(map[string]bool)
	for _, r := range a.Recipients {
		want[r.Email] = true
		if byEmail[r.Email].Unsubscribed {
			result.Unsubscribed++
		}
	}
	var remove []string
	present := make(map[string]bool)
	for _, m := range members {
		email, ok := normalizeEmail(m.Email)
		if !ok {
			return result, errors.New("managed segment contains an invalid email; inspect Resend before syncing")
		}
		if !want[email] {
			remove = append(remove, m.ID)
		} else {
			present[email] = true
		}
	}
	var add []string
	for _, r := range a.Recipients {
		if !present[r.Email] {
			add = append(add, r.Email)
			if byEmail[r.Email].ID == "" {
				result.Create++
			}
		}
	}
	sort.Strings(remove)
	result.Add, result.Remove = len(add), len(remove)
	if !apply {
		return result, nil
	}
	if err := checkAudienceAge(a); err != nil {
		return result, err
	}
	if result.SegmentID == "" {
		if len(want) == 0 {
			return result, errors.New("no recipients; no segment created")
		}
		result.SegmentID, err = api.CreateSegment(ctx, a.Segment)
		if err != nil {
			return result, err
		}
	}
	for _, id := range remove {
		if err := api.RemoveMember(ctx, result.SegmentID, id); err != nil {
			return result, fmt.Errorf("remove stale membership: %w", err)
		}
	}
	for _, email := range add {
		if err := checkAudienceAge(a); err != nil {
			return result, err
		}
		id := byEmail[email].ID
		if id == "" {
			id, err = api.CreateContact(ctx, email)
			if err != nil {
				return result, fmt.Errorf("create contact: %w", err)
			}
		}
		if err := api.AddMember(ctx, result.SegmentID, id); err != nil {
			return result, fmt.Errorf("add membership: %w", err)
		}
	}
	verified, err := api.Members(ctx, result.SegmentID)
	if err != nil {
		return result, err
	}
	if len(verified) != len(want) {
		return result, errors.New("segment verification failed; rerun sync before sending")
	}
	for _, m := range verified {
		email, _ := normalizeEmail(m.Email)
		if !want[email] {
			return result, errors.New("segment changed during sync; rerun before sending")
		}
		delete(want, email)
	}
	result.Applied = true
	return result, nil
}

func checkAudienceAge(a Audience) error {
	if a.CapturedAt.IsZero() || time.Since(a.CapturedAt) > 15*time.Minute || time.Until(a.CapturedAt) > time.Minute {
		return errors.New("audience snapshot expired; take a fresh snapshot and rerun")
	}
	return nil
}
