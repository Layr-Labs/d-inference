package resend

import (
	"context"
	"errors"
	"net/http"
	"net/url"
)

type identified interface{ identifier() string }

func list[T identified](ctx context.Context, c *Client, path string) ([]T, error) {
	var all []T
	cursor := ""
	seen := make(map[string]bool)
	for {
		query := url.Values{"limit": {"100"}}
		if cursor != "" {
			query.Set("after", cursor)
		}
		var page struct {
			Data    []T   `json:"data"`
			HasMore *bool `json:"has_more"`
		}
		if err := c.request(ctx, http.MethodGet, path+"?"+query.Encode(), nil, &page, ""); err != nil {
			return nil, err
		}
		if page.HasMore == nil || page.Data == nil {
			return nil, errors.New("Resend pagination missing data or has_more")
		}
		for _, item := range page.Data {
			id := item.identifier()
			if id == "" || seen[id] {
				return nil, errors.New("Resend pagination repeated or omitted an ID")
			}
			seen[id] = true
			all = append(all, item)
		}
		if !*page.HasMore {
			return all, nil
		}
		if len(page.Data) == 0 || len(all) > 100000 {
			return nil, errors.New("Resend pagination did not terminate")
		}
		cursor = page.Data[len(page.Data)-1].identifier()
	}
}
