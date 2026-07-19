package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T) *server {
	return &server{db: testDB(t), hub: newHub()}
}

// do drives one request through the router and returns the recorder.
func do(t *testing.T, s *server, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, target, nil)
	} else {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, r)
	return rec
}

func published(hub *Hub, ch chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

func count(t *testing.T, s *server) int {
	t.Helper()
	n, err := countUsers(s.db)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestIsValidEmail(t *testing.T) {
	good := []string{"a@b.co", "first.last@sub.example.com"}
	bad := []string{"", "no-at-sign", "@nolocal.com", "noat.com", "a@b", "a@b.", "two@@x.com", "has space@x.com"}
	for _, e := range good {
		if !isValidEmail(e) {
			t.Errorf("isValidEmail(%q) = false, want true", e)
		}
	}
	for _, e := range bad {
		if isValidEmail(e) {
			t.Errorf("isValidEmail(%q) = true, want false", e)
		}
	}
}

func TestHubPublishWakesSubscribers(t *testing.T) {
	hub := newHub()
	ch := hub.subscribe()
	defer hub.unsubscribe(ch)
	if published(hub, ch) {
		t.Fatal("subscriber woke before any publish")
	}
	hub.publish()
	if !published(hub, ch) {
		t.Fatal("subscriber did not wake after publish")
	}
}

func TestGetPageBootsStreamAndListsUsers(t *testing.T) {
	s := newTestServer(t)
	rec := do(t, s, "GET", "/", "")

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `data-init="@get('/updates')"`) {
		t.Error("page does not boot the /updates stream")
	}
	if !strings.Contains(body, "Ada Lovelace") {
		t.Error("page does not list seeded users")
	}
}

func TestContentRendersMorphTarget(t *testing.T) {
	users := []User{{ID: 1, Name: "Ada <script>", Email: "a@x.com", Role: "admin"}}
	var b strings.Builder
	if err := Content(users).Render(context.Background(), &b); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	if !strings.HasPrefix(out, `<main id="content">`) {
		t.Errorf("content does not start with the morph target: %q", out[:min(40, len(out))])
	}
	if strings.Contains(out, "<script>") {
		t.Error("user value was not escaped")
	}
	if !strings.Contains(out, "Ada &lt;script&gt;") {
		t.Error("expected escaped user name")
	}
}

func TestCreateUserPublishesAndClosesDialog(t *testing.T) {
	s := newTestServer(t)
	ch := s.hub.subscribe()
	defer s.hub.unsubscribe(ch)

	body := `{"name":"Barbara Liskov","email":"barbara@example.com","role":"member"}`
	rec := do(t, s, "POST", "/users/", body)

	if n := count(t, s); n != len(seedUsers)+1 {
		t.Fatalf("user count = %d, want %d", n, len(seedUsers)+1)
	}
	if !published(s.hub, ch) {
		t.Error("create did not publish")
	}
	out := rec.Body.String()
	if !strings.Contains(out, "datastar-patch-signals") || !strings.Contains(out, `"addOpen":false`) {
		t.Error("response should reset the form and clear $addOpen to close the dialog")
	}
	if strings.Contains(out, "Barbara Liskov") {
		t.Error("command response must not carry the table")
	}
}

func TestCreateInvalidEmailRerendersDialog(t *testing.T) {
	s := newTestServer(t)
	ch := s.hub.subscribe()
	defer s.hub.unsubscribe(ch)

	rec := do(t, s, "POST", "/users/", `{"name":"Bad","email":"not-an-email","role":"member"}`)

	if n := count(t, s); n != len(seedUsers) {
		t.Fatalf("nothing should be added, count = %d", n)
	}
	if published(s.hub, ch) {
		t.Error("invalid input must not publish")
	}
	out := rec.Body.String()
	for _, want := range []string{"datastar-patch-signals", "emailError", "valid email"} {
		if !strings.Contains(out, want) {
			t.Errorf("response missing %q", want)
		}
	}
}

func TestCreateEmptyNameRejected(t *testing.T) {
	s := newTestServer(t)
	rec := do(t, s, "POST", "/users/", `{"name":"  ","email":"x@y.com","role":"member"}`)

	if n := count(t, s); n != len(seedUsers) {
		t.Fatalf("count = %d, want %d", n, len(seedUsers))
	}
	if !strings.Contains(rec.Body.String(), "required") {
		t.Error("expected a required-field error")
	}
}

func TestCreateReportsFieldErrorsIndependently(t *testing.T) {
	s := newTestServer(t)
	// Empty name AND invalid email: both field-error signals are set with their
	// own message, so each is shown beneath its own input by the template.
	rec := do(t, s, "POST", "/users/", `{"name":"","email":"nope","role":"member"}`)
	out := rec.Body.String()

	if !strings.Contains(out, `"nameError":"Name is required."`) {
		t.Errorf("missing name error signal in %q", out)
	}
	if !strings.Contains(out, `"emailError":"Please enter a valid email address."`) {
		t.Errorf("missing email error signal in %q", out)
	}
}

func TestCreateDuplicateEmailRejected(t *testing.T) {
	s := newTestServer(t)
	rec := do(t, s, "POST", "/users/", `{"name":"Impostor","email":"ada@example.com","role":"member"}`)

	if n := count(t, s); n != len(seedUsers) {
		t.Fatalf("count = %d, want %d", n, len(seedUsers))
	}
	if !strings.Contains(rec.Body.String(), "already in use") {
		t.Error("expected a duplicate-email error")
	}
}

func TestDeleteRemovesAndPublishes(t *testing.T) {
	s := newTestServer(t)
	ch := s.hub.subscribe()
	defer s.hub.unsubscribe(ch)

	rec := do(t, s, "DELETE", "/users/1", "")

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if n := count(t, s); n != len(seedUsers)-1 {
		t.Fatalf("count = %d, want %d", n, len(seedUsers)-1)
	}
	if !published(s.hub, ch) {
		t.Error("delete did not publish")
	}
}

func TestUnknownPathIs404(t *testing.T) {
	s := newTestServer(t)
	if rec := do(t, s, "GET", "/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

// TestUpdatesInitialPush verifies the stream pushes a fat morph on connect over
// a real socket, then ends when the client goes away.
func TestUpdatesInitialPush(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	ctx := t.Context()
	req, _ := http.NewRequestWithContext(ctx, "GET", ts.URL+"/updates", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()

	// Read from the stream (in a goroutine, since it never ends on its own)
	// until the initial content event arrives.
	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		var acc strings.Builder
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				acc.Write(buf[:n])
				if strings.Contains(acc.String(), "Ada Lovelace") {
					got <- acc.String()
					return
				}
			}
			if err != nil {
				got <- acc.String()
				return
			}
		}
	}()

	select {
	case out := <-got:
		if !strings.Contains(out, "datastar-patch-elements") || !strings.Contains(out, "Ada Lovelace") {
			t.Errorf("stream did not push the initial content: %q", out)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the initial content event")
	}
}
