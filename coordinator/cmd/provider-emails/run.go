package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/mail"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail"
	"github.com/eigeninference/d-inference/coordinator/provideremail/resend"
	"github.com/google/uuid"
)

const usage = `Usage: provider-emails <preview|sync|draft|test> -config campaign.json [options]

preview  Read fleet data and print counts; optionally write a private audience report.
sync     Compare the fleet audience with Resend; -apply reconciles membership.
draft    Compare the audience; -apply syncs and creates/reuses an unsent broadcast.
test     Render a test; -apply sends only to the explicitly supplied -to address.

Environment: PROVIDER_EMAIL_DATABASE_URL (read-only database), RESEND_API_KEY.
No command sends or schedules a provider campaign. Review and send in Resend.
`

func run(ctx context.Context, args []string, out io.Writer, getenv func(string) string) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		_, err := fmt.Fprint(out, usage)
		return err
	}
	command := args[0]
	if command != "preview" && command != "sync" && command != "draft" && command != "test" {
		return errors.New("unknown command; use --help")
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(out)
	configPath := fs.String("config", "", "campaign JSON file (required)")
	snapshotPath := fs.String("snapshot", "", "use a recently captured JSON fixture instead of Postgres")
	reportPath := fs.String("report", "", "write recipient report to a new private file (contains email addresses)")
	htmlPath := fs.String("html", "", "write rendered email HTML to a new file")
	apply := fs.Bool("apply", false, "apply Resend changes; test sends only to -to")
	to := fs.String("to", "", "single test recipient; valid only with test")
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 || *configPath == "" {
		return errors.New("-config is required; positional arguments are not accepted")
	}
	if command == "preview" && *apply || command != "test" && *to != "" || command == "test" && (*snapshotPath != "" || *reportPath != "") {
		return errors.New("options do not apply to this command")
	}
	f, err := os.Open(*configPath)
	if err != nil {
		return err
	}
	campaign, err := provideremail.DecodeCampaign(f)
	f.Close()
	if err != nil {
		return err
	}
	draft, err := provideremail.Render(campaign, command == "test")
	if err != nil {
		return err
	}
	if *htmlPath != "" {
		if err := writePrivateFile(*htmlPath, []byte(draft.HTML)); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	if command == "test" {
		address, err := mail.ParseAddress(*to)
		if err != nil || address.Address != *to || strings.ContainsAny(*to, "\r\n") {
			return errors.New("test requires -to with exactly one email address")
		}
		if !*apply {
			_, err := fmt.Fprintln(out, "Test rendered; no email sent. Use -apply to send to the selected test address.")
			return err
		}
		client, err := resend.New(getenv("RESEND_API_KEY"))
		if err != nil {
			return err
		}
		id, err := client.SendTest(ctx, draft, *to, "provider-email-test/"+uuid.NewString())
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(out, "Test email accepted by Resend:", id, "(verify delivery in Resend and the inbox)")
		return err
	}
	snapshot, err := loadSnapshot(ctx, *snapshotPath, getenv("PROVIDER_EMAIL_DATABASE_URL"), campaign.ActiveWithinDays)
	if err != nil {
		return err
	}
	audience, err := provideremail.BuildAudience(campaign, snapshot, time.Now().UTC())
	if err != nil {
		return err
	}
	if *reportPath != "" {
		raw, err := json.MarshalIndent(audience, "", "  ")
		if err != nil {
			return err
		}
		if err := writePrivateFile(*reportPath, append(raw, '\n')); err != nil {
			return err
		}
	}
	// Stdout intentionally has no account IDs, machine IDs or email addresses.
	if err := json.NewEncoder(out).Encode(struct {
		Campaign string               `json:"campaign"`
		Segment  string               `json:"segment"`
		Counts   provideremail.Counts `json:"counts"`
	}{campaign.ID, audience.Segment, audience.Counts}); err != nil {
		return err
	}
	if command == "preview" {
		return nil
	}
	client, err := resend.New(getenv("RESEND_API_KEY"))
	if err != nil {
		return err
	}
	result, err := provideremail.Sync(ctx, client, campaign, audience, *apply)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(out).Encode(result); err != nil {
		return err
	}
	if command == "draft" && *apply {
		if audience.Counts.Recipients == 0 {
			return errors.New("empty audience synced; no draft created")
		}
		id, err := provideremail.EnsureDraft(ctx, client, campaign, result.SegmentID)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(out, "Unsent broadcast:", id, "— review in https://resend.com/broadcasts")
		return err
	}
	return nil
}

func loadSnapshot(ctx context.Context, path, databaseURL string, activeDays int) (provideremail.Snapshot, error) {
	if path != "" {
		f, err := os.Open(path)
		if err != nil {
			return provideremail.Snapshot{}, err
		}
		defer f.Close()
		return provideremail.DecodeSnapshot(f)
	}
	if databaseURL == "" {
		return provideremail.Snapshot{}, errors.New("PROVIDER_EMAIL_DATABASE_URL or -snapshot is required")
	}
	return provideremail.ReadSnapshot(ctx, databaseURL, activeDays)
}

func writePrivateFile(path string, raw []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	if _, err := f.Write(raw); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
