package provideremail

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail/resend"
)

type fakeAPI struct {
	segments   []resend.Segment
	contacts   []resend.Contact
	members    []resend.Contact
	broadcasts []resend.Broadcast
	mutations  []string
	failRemove bool
	pageError  bool
}

func (f *fakeAPI) Segments(context.Context) ([]resend.Segment, error) { return f.segments, nil }
func (f *fakeAPI) Contacts(context.Context) ([]resend.Contact, error) {
	if f.pageError {
		return nil, errors.New("pagination failed")
	}
	return f.contacts, nil
}
func (f *fakeAPI) Members(context.Context, string) ([]resend.Contact, error) {
	return append([]resend.Contact(nil), f.members...), nil
}
func (f *fakeAPI) Broadcasts(context.Context) ([]resend.Broadcast, error) { return f.broadcasts, nil }
func (f *fakeAPI) CreateSegment(_ context.Context, name string) (string, error) {
	f.mutations = append(f.mutations, "segment")
	f.segments = append(f.segments, resend.Segment{ID: "segment", Name: name})
	return "segment", nil
}
func (f *fakeAPI) CreateContact(_ context.Context, email string) (string, error) {
	f.mutations = append(f.mutations, "contact")
	id := fmt.Sprint(len(f.contacts))
	f.contacts = append(f.contacts, resend.Contact{ID: id, Email: email})
	return id, nil
}
func (f *fakeAPI) AddMember(_ context.Context, segment, id string) error {
	f.mutations = append(f.mutations, "add")
	for _, c := range f.contacts {
		if c.ID == id {
			f.members = append(f.members, c)
			return nil
		}
	}
	return errors.New("missing contact")
}
func (f *fakeAPI) RemoveMember(_ context.Context, segment, id string) error {
	f.mutations = append(f.mutations, "remove")
	if f.failRemove {
		return errors.New("remove failed")
	}
	for i, c := range f.members {
		if c.ID == id {
			f.members = append(f.members[:i], f.members[i+1:]...)
			break
		}
	}
	return nil
}
func (f *fakeAPI) CreateDraft(_ context.Context, d resend.Draft) (string, error) {
	f.mutations = append(f.mutations, "draft")
	f.broadcasts = append(f.broadcasts, resend.Broadcast{ID: "draft", Name: d.Name, Status: "draft", SegmentID: d.SegmentID})
	return "draft", nil
}

func testAudience(t *testing.T, c Campaign) Audience {
	t.Helper()
	now := time.Now().UTC()
	a, err := BuildAudience(c, Snapshot{CapturedAt: now, Machines: []Machine{testMachine(now, "m")}}, now)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func TestSyncDryRunIdempotencyAndPreferences(t *testing.T) {
	c := testCampaign()
	a := testAudience(t, c)
	f := &fakeAPI{segments: []resend.Segment{{ID: "segment", Name: c.SegmentName()}}, contacts: []resend.Contact{{ID: "contact", Email: "owner@example.com", Unsubscribed: true}}, members: []resend.Contact{{ID: "old", Email: "old@example.com"}}}
	result, err := Sync(context.Background(), f, c, a, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.mutations) != 0 || result.Add != 1 || result.Remove != 1 || result.Unsubscribed != 1 {
		t.Fatalf("%+v / %+v", result, f.mutations)
	}
	result, err = Sync(context.Background(), f, c, a, true)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Applied || len(f.mutations) != 2 || f.mutations[0] != "remove" || !f.contacts[0].Unsubscribed {
		t.Fatalf("%+v / %+v", result, f)
	}
	f.mutations = nil
	if _, err = Sync(context.Background(), f, c, a, true); err != nil {
		t.Fatal(err)
	}
	if len(f.mutations) != 0 {
		t.Fatal("repeat sync changed remote state")
	}
	for i := 0; i < 2; i++ {
		if _, err = EnsureDraft(context.Background(), f, c, "segment"); err != nil {
			t.Fatal(err)
		}
	}
	if len(f.broadcasts) != 1 {
		t.Fatal("duplicate draft")
	}
}

func TestSyncRemovesUpdatedOwnersEvenForEmptyAudience(t *testing.T) {
	c := testCampaign()
	a := testAudience(t, c)
	a.Recipients = nil
	a.Counts.Recipients = 0
	f := &fakeAPI{segments: []resend.Segment{{ID: "segment", Name: c.SegmentName()}}, members: []resend.Contact{{ID: "old", Email: "old@example.com"}}}
	result, err := Sync(context.Background(), f, c, a, true)
	if err != nil || !result.Applied || len(f.members) != 0 {
		t.Fatalf("%+v %v", result, err)
	}
}

func TestSyncStopsOnFailureOrActiveBroadcast(t *testing.T) {
	c := testCampaign()
	a := testAudience(t, c)
	for _, status := range []string{"scheduled", "sending", "queued", "unknown"} {
		f := &fakeAPI{segments: []resend.Segment{{ID: "segment", Name: c.SegmentName()}}, broadcasts: []resend.Broadcast{{SegmentID: "segment", Status: status}}}
		if _, err := Sync(context.Background(), f, c, a, true); err == nil || len(f.mutations) > 0 {
			t.Fatalf("status %s allowed mutation", status)
		}
	}
	f := &fakeAPI{segments: []resend.Segment{{ID: "segment", Name: c.SegmentName()}}, members: []resend.Contact{{ID: "old", Email: "old@example.com"}}, failRemove: true}
	if _, err := Sync(context.Background(), f, c, a, true); err == nil || len(f.mutations) != 1 {
		t.Fatal("continued after removal failure")
	}
	f = &fakeAPI{pageError: true}
	if _, err := Sync(context.Background(), f, c, a, true); err == nil || len(f.mutations) != 0 {
		t.Fatal("mutated on incomplete remote snapshot")
	}
}

func TestDraftNeverReusesSentCampaign(t *testing.T) {
	c := testCampaign()
	f := &fakeAPI{broadcasts: []resend.Broadcast{{ID: "sent", Name: c.DraftName(), Status: "sent", SegmentID: "segment"}}}
	if _, err := EnsureDraft(context.Background(), f, c, "segment"); err == nil || len(f.mutations) > 0 {
		t.Fatal("reused sent campaign")
	}
}
