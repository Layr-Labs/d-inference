package notifications

import (
	"fmt"
	"html"
	"strings"
)

func buildProviderAlertEmail(from, to, name string, reasons []AlertReason, consoleURL, unsubscribeURL string) Email {
	subject := fmt.Sprintf("Action needed: %s needs attention on Darkbloom", name)
	if len(reasons) == 1 && reasons[0].Key == alertReasonOffline {
		subject = fmt.Sprintf("Action needed: %s is offline on Darkbloom", name)
	}
	return Email{
		From:           from,
		To:             to,
		Subject:        subject,
		Text:           buildTextEmail(name, reasons, consoleURL),
		HTML:           buildHTMLEmail(name, reasons, consoleURL),
		UnsubscribeURL: unsubscribeURL,
	}
}

func buildTextEmail(name string, reasons []AlertReason, consoleURL string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s needs attention on Darkbloom.\n\n", name)
	for _, r := range reasons {
		fmt.Fprintf(&b, "- %s: %s %s\n", r.Title, r.Detail, r.Action)
	}
	if consoleURL != "" {
		fmt.Fprintf(&b, "\nOpen your provider dashboard: %s\n", consoleURL)
	}
	b.WriteString("\nDarkbloom only sends this alert when a machine stops earning or needs action. Repeated alerts for the same issue are rate-limited.\n")
	return b.String()
}

func buildHTMLEmail(name string, reasons []AlertReason, consoleURL string) string {
	var b strings.Builder
	b.WriteString("<!doctype html><html><body>")
	fmt.Fprintf(&b, "<p>%s needs attention on Darkbloom.</p>", html.EscapeString(name))
	b.WriteString("<ul>")
	for _, r := range reasons {
		fmt.Fprintf(&b, "<li><strong>%s</strong><br>%s<br>%s</li>",
			html.EscapeString(r.Title),
			html.EscapeString(r.Detail),
			html.EscapeString(r.Action),
		)
	}
	b.WriteString("</ul>")
	if consoleURL != "" {
		fmt.Fprintf(&b, `<p><a href="%s">Open your provider dashboard</a></p>`, html.EscapeString(consoleURL))
	}
	b.WriteString("<p>Repeated alerts for the same issue are rate-limited.</p>")
	b.WriteString("</body></html>")
	return b.String()
}
