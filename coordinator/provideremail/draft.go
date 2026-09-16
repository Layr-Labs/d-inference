package provideremail

import (
	"context"
	"errors"
)

// EnsureDraft reuses a matching draft on rerun. Sent or edited campaigns need
// a new campaign ID or message; no automatic sending or scheduling is exposed.
func EnsureDraft(ctx context.Context, api AudienceAPI, c Campaign, segmentID string) (string, error) {
	items, err := api.Broadcasts(ctx)
	if err != nil {
		return "", err
	}
	id := ""
	for _, b := range items {
		if b.Name == c.DraftName() {
			if b.Status != "draft" || id != "" || b.SegmentID != segmentID {
				return "", errors.New("campaign already sent, scheduled, or ambiguous; use a new campaign ID for a reminder")
			}
			id = b.ID
		}
	}
	if id != "" {
		return id, nil
	}
	draft, err := Render(c, false)
	if err != nil {
		return "", err
	}
	draft.SegmentID = segmentID
	return api.CreateDraft(ctx, draft)
}
