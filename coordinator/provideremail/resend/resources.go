package resend

import (
	"context"
	"errors"
	"net/http"
	"net/url"
)

type Segment struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s Segment) identifier() string { return s.ID }

type Contact struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	Unsubscribed bool   `json:"unsubscribed"`
}

func (c Contact) identifier() string { return c.ID }

type Broadcast struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Status    string `json:"status"`
	SegmentID string `json:"segment_id"`
}

func (b Broadcast) identifier() string { return b.ID }

type Draft struct {
	Name      string `json:"name"`
	SegmentID string `json:"segment_id"`
	From      string `json:"from"`
	ReplyTo   string `json:"reply_to"`
	Subject   string `json:"subject"`
	HTML      string `json:"html"`
	Text      string `json:"text"`
	TopicID   string `json:"topic_id,omitempty"`
	// No send or scheduled_at fields: campaigns are reviewed in the dashboard.
}

func (c *Client) Segments(ctx context.Context) ([]Segment, error) {
	return list[Segment](ctx, c, "/segments")
}

func (c *Client) Contacts(ctx context.Context) ([]Contact, error) {
	return list[Contact](ctx, c, "/contacts")
}

func (c *Client) Members(ctx context.Context, segment string) ([]Contact, error) {
	return list[Contact](ctx, c, "/segments/"+url.PathEscape(segment)+"/contacts")
}

func (c *Client) Broadcasts(ctx context.Context) ([]Broadcast, error) {
	return list[Broadcast](ctx, c, "/broadcasts")
}

func (c *Client) CreateSegment(ctx context.Context, name string) (string, error) {
	var result Segment
	err := c.request(ctx, http.MethodPost, "/segments", map[string]string{"name": name}, &result, "")
	return requireID(result.ID, err)
}

func (c *Client) CreateContact(ctx context.Context, email string) (string, error) {
	var result Contact
	// Omit unsubscribed and topics entirely. Existing preferences must never
	// be overwritten by a sync, including if creation races another operator.
	err := c.request(ctx, http.MethodPost, "/contacts", map[string]string{"email": email}, &result, "")
	return requireID(result.ID, err)
}

func (c *Client) AddMember(ctx context.Context, segment, contact string) error {
	return c.request(ctx, http.MethodPost, "/contacts/"+url.PathEscape(contact)+"/segments/"+url.PathEscape(segment), nil, nil, "")
}

func (c *Client) RemoveMember(ctx context.Context, segment, contact string) error {
	err := c.request(ctx, http.MethodDelete, "/contacts/"+url.PathEscape(contact)+"/segments/"+url.PathEscape(segment), nil, nil, "")
	var apiErr *APIError
	if errors.As(err, &apiErr) && apiErr.Status == 404 {
		return nil
	}
	return err
}

func (c *Client) CreateDraft(ctx context.Context, draft Draft) (string, error) {
	var result Broadcast
	err := c.request(ctx, http.MethodPost, "/broadcasts", draft, &result, "")
	return requireID(result.ID, err)
}

func (c *Client) SendTest(ctx context.Context, draft Draft, to, key string) (string, error) {
	var result struct {
		ID string `json:"id"`
	}
	err := c.request(ctx, http.MethodPost, "/emails", map[string]any{
		"from": draft.From, "reply_to": draft.ReplyTo, "to": []string{to},
		"subject": "[TEST] " + draft.Subject, "html": draft.HTML, "text": draft.Text,
	}, &result, key)
	return requireID(result.ID, err)
}

func requireID(id string, err error) (string, error) {
	if err != nil {
		return "", err
	}
	if id == "" {
		return "", errors.New("Resend returned an empty resource ID")
	}
	return id, nil
}
