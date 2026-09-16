package provideremail

import (
	"bytes"
	"fmt"
	"html/template"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/provideremail/resend"
)

var noticeTemplate = template.Must(template.New("notice").Delims("[[", "]]").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>[[.Subject]]</title></head>
<body style="margin:0;background:#f5f5f3;color:#20211f;font-family:Arial,Helvetica,sans-serif">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td style="padding:36px 16px">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:580px;margin:auto;background:white;border:1px solid #e3e4df;border-radius:12px"><tr><td style="padding:36px">
<p style="margin:0 0 28px;font-size:14px;font-weight:bold;letter-spacing:2px">DARKBLOOM</p>
[[if .Test]]<p style="padding:12px;background:#fff2ce">Integration test only. This is not a provider update requirement.</p>[[end]]
<p style="font-size:12px;text-transform:uppercase;letter-spacing:1px;color:#65685f">[[.Severity]] provider notice</p>
<h1 style="font-size:26px;line-height:1.25;font-weight:600">[[.Subject]]</h1>
[[if .Target]]<p style="font-size:16px;line-height:1.6">[[.Target]]</p>[[end]]
[[if .Deadline]]<p style="font-size:16px;line-height:1.6"><strong>Update by [[.Deadline]].</strong></p>[[end]]
[[range .Paragraphs]]<p style="font-size:16px;line-height:1.6;white-space:pre-line">[[.]]</p>[[end]]
<p style="margin:30px 0"><a href="[[.InstructionsURL]]" style="display:inline-block;padding:14px 20px;background:#252923;color:white;text-decoration:none;border-radius:6px">View update instructions</a></p>
<p style="font-size:13px;line-height:1.5;color:#65685f">This notice is based on recently reported provider information. If you already updated, reconnect your provider so its status can refresh. Reply to this email if you need help.</p>
[[if .Test]]<p style="font-size:12px;color:#65685f">Sent only to the explicitly selected test recipient.</p>[[else]]<p style="font-size:12px"><a href="{{{RESEND_UNSUBSCRIBE_URL}}}" style="color:#65685f">Email preferences / unsubscribe</a></p>[[end]]
</td></tr></table></td></tr></table></body></html>`))

func Render(c Campaign, test bool) (resend.Draft, error) {
	if err := c.Validate(); err != nil {
		return resend.Draft{}, err
	}
	target := ""
	switch c.Audience {
	case "provider_update":
		target = "Update the Darkbloom provider to version " + c.MinimumVersion + " or newer."
	case "macos_update":
		target = "Update macOS to version " + c.MinimumVersion + " or a newer Darkbloom-supported version."
	}
	data := struct {
		Message
		Target     string
		Paragraphs []string
		Test       bool
	}{c.Message, target, strings.Split(c.Message.Body, "\n\n"), test}
	var html bytes.Buffer
	if err := noticeTemplate.Execute(&html, data); err != nil {
		return resend.Draft{}, err
	}
	text := c.Message.Subject + "\n\n"
	if test {
		text += "INTEGRATION TEST ONLY — this is not a provider update requirement.\n\n"
	}
	text += fmt.Sprintf("%s provider notice\n%s\n\n", c.Message.Severity, target)
	if c.Message.Deadline != "" {
		text += "Update by " + c.Message.Deadline + ".\n\n"
	}
	text += c.Message.Body + "\n\nView update instructions: " + c.Message.InstructionsURL
	text += "\n\nIf you already updated, reconnect your provider so its status can refresh. Reply to this email if you need help."
	if !test {
		text += "\n\nEmail preferences / unsubscribe: {{{RESEND_UNSUBSCRIBE_URL}}}"
	}
	return resend.Draft{Name: c.DraftName(), From: c.Message.From, ReplyTo: c.Message.ReplyTo,
		Subject: c.Message.Subject, HTML: html.String(), Text: text, TopicID: c.Message.TopicID}, nil
}
