// HTTP/1.1 server built on net/http and the datastar-go SDK, with a
// CQRS-flavored Datastar UI.
//
// Reads and writes are separated:
//   - The read model is a long-lived Server-Sent-Events stream at GET /updates
//     (opened by the page via data-init). Whenever the data changes it pushes a
//     "fat" morph of the whole #content region.
//   - Commands (POST /users/, DELETE /users/{id}) mutate the database and then
//     publish() to a shared Hub, which wakes every open stream so all connected
//     clients re-render. Commands themselves return only UI feedback (e.g. a
//     re-rendered dialog on a validation error), never the table.

package main

import (
	"embed"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cvilsmeier/sqinn-go/v2"
	datastar "github.com/starfederation/datastar-go/datastar"
)

//go:embed static
var staticFS embed.FS

// heartbeat is how often an idle /updates stream emits a keep-alive comment so
// intermediaries do not close it.
const heartbeat = 15 * time.Second

// createSignals is the subset of Datastar signals read when creating a user.
type createSignals struct {
	Name  string `json:"name"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

// Hub broadcasts "data changed" to every open /updates stream. It replaces the
// Zig version's atomic version counter with a set of subscriber channels: a
// change wakes each subscriber exactly once, with no idle polling.
type Hub struct {
	mu   sync.Mutex
	subs map[chan struct{}]struct{}
}

func newHub() *Hub {
	return &Hub{subs: make(map[chan struct{}]struct{})}
}

// subscribe registers a stream and returns its wake-up channel (buffered so a
// publish never blocks and repeated publishes coalesce into one pending wake).
func (h *Hub) subscribe() chan struct{} {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *Hub) unsubscribe(ch chan struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.subs, ch)
}

// publish signals that the data changed.
func (h *Hub) publish() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- struct{}{}:
		default: // a wake is already pending for this subscriber
		}
	}
}

// server bundles the shared dependencies handed to every request.
type server struct {
	db  *sqinn.Sqinn
	hub *Hub
}

// routes builds the request multiplexer. net/http's method-aware patterns give
// 405 for a known path with the wrong method and 404 for an unknown path.
func (s *server) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", s.handlePage)
	mux.HandleFunc("GET /users", s.handlePage)
	mux.HandleFunc("GET /index.html", s.handlePage)

	mux.HandleFunc("GET /updates", s.handleUpdates)

	mux.Handle("GET /static/", staticHandler())

	mux.HandleFunc("POST /users/{$}", s.handleCreate)
	mux.HandleFunc("POST /users", s.handleCreate)

	mux.HandleFunc("DELETE /users/{id}", s.handleDelete)

	return mux
}

// --- Read model ------------------------------------------------------------

func (s *server) handlePage(w http.ResponseWriter, r *http.Request) {
	users, err := allUsers(s.db)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		log.Printf("page: %v", err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := Page(users).Render(r.Context(), w); err != nil {
		log.Printf("page render: %v", err)
	}
}

// handleUpdates is the long-lived SSE read model. It pushes a fat morph of
// #content on connect and on every subsequent data change, and a keep-alive
// comment when idle. The request context ends the stream when the client leaves.
func (s *server) handleUpdates(w http.ResponseWriter, r *http.Request) {
	sse := datastar.NewSSE(w, r)
	rc := http.NewResponseController(w)

	ch := s.hub.subscribe()
	defer s.hub.unsubscribe(ch)

	if err := s.pushContent(sse); err != nil {
		log.Printf("updates: initial push: %v", err)
		return
	}

	ticker := time.NewTicker(heartbeat)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ch:
			if err := s.pushContent(sse); err != nil {
				log.Printf("updates: push: %v", err)
				return
			}
		case <-ticker.C:
			// SSE comment line; a write error surfaces a dropped client.
			if _, err := io.WriteString(w, ": keep-alive\n\n"); err != nil {
				return
			}
			if err := rc.Flush(); err != nil {
				return
			}
		}
	}
}

// pushContent renders the current #content region into one patch-elements event.
func (s *server) pushContent(sse *datastar.ServerSentEventGenerator) error {
	users, err := allUsers(s.db)
	if err != nil {
		return err
	}
	return sse.PatchElementTempl(Content(users))
}

// --- Commands --------------------------------------------------------------

// handleCreate validates the submitted Datastar signals and creates a user. On
// any problem it re-renders the add dialog (targeted by id) with an error and
// leaves the entered values in place. On success it publishes the change (the
// stream re-renders the table), clears the form, and closes the dialog.
func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	var sig createSignals
	if err := datastar.ReadSignals(r, &sig); err != nil {
		s.dialogError(w, r, "Could not read the submitted form.", "")
		return
	}

	name := strings.TrimSpace(sig.Name)
	email := strings.TrimSpace(sig.Email)
	role := sig.Role
	if role == "" {
		role = "member"
	}

	// Validate each field independently so every offending field shows its own
	// message directly beneath it.
	var nameErr, emailErr string
	if name == "" {
		nameErr = "Name is required."
	}
	if email == "" {
		emailErr = "Email is required."
	} else if !isValidEmail(email) {
		emailErr = "Please enter a valid email address."
	}
	if nameErr != "" || emailErr != "" {
		s.dialogError(w, r, nameErr, emailErr)
		return
	}

	if err := insertUser(s.db, name, email, role); err != nil {
		if errors.Is(err, ErrDuplicateEmail) {
			s.dialogError(w, r, "", "That email is already in use.")
			return
		}
		http.Error(w, "internal error", http.StatusInternalServerError)
		log.Printf("create: %v", err)
		return
	}

	s.hub.publish()

	// Success: the stream refreshes the table; here we just reset the form,
	// clear any field errors, and close the dialog (addOpen=false drives
	// data-effect to close the modal). The dialog element is never patched.
	sse := datastar.NewSSE(w, r)
	if err := sse.MarshalAndPatchSignals(resetSignals{Role: "member"}); err != nil {
		log.Printf("create: reset signals: %v", err)
	}
}

// resetSignals clears the add-form fields and field errors and closes the dialog
// (addOpen=false) after a successful create.
type resetSignals struct {
	Name       string `json:"name"`
	Email      string `json:"email"`
	Role       string `json:"role"`
	NameError  string `json:"nameError"`
	EmailError string `json:"emailError"`
	AddOpen    bool   `json:"addOpen"`
}

// fieldErrors reports per-field validation messages to the open dialog. Both
// fields are always sent (empty clears a stale message on that field).
type fieldErrors struct {
	NameError  string `json:"nameError"`
	EmailError string `json:"emailError"`
}

// handleDelete deletes a user and publishes. The table refresh arrives over the
// stream; the confirmation dialog was already closed client-side.
func (s *server) handleDelete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if err := deleteUser(s.db, id); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		log.Printf("delete: %v", err)
		return
	}
	s.hub.publish()

	// Acknowledge with an empty SSE response; the table refresh rides the stream.
	datastar.NewSSE(w, r)
}

// dialogError reports per-field validation messages by patching the
// $nameError / $emailError signals. The dialog element is untouched, so it stays
// open (data-show/data-text surface the messages beneath their inputs).
func (s *server) dialogError(w http.ResponseWriter, r *http.Request, nameErr, emailErr string) {
	sse := datastar.NewSSE(w, r)
	if err := sse.MarshalAndPatchSignals(fieldErrors{NameError: nameErr, EmailError: emailErr}); err != nil {
		log.Printf("dialog error patch: %v", err)
	}
}

// isValidEmail is a basic email check equivalent to `^[^@\s]+@[^@\s]+\.[^@\s]+$`:
// a non-empty local part, a single '@', and a domain containing a dot that is
// not at either end, with no spaces or control characters anywhere.
func isValidEmail(email string) bool {
	at := strings.IndexByte(email, '@')
	if at <= 0 {
		return false // no '@' or empty local part
	}
	if strings.LastIndexByte(email, '@') != at {
		return false // more than one '@'
	}
	domain := email[at+1:]
	dot := strings.LastIndexByte(domain, '.')
	if dot <= 0 || dot == len(domain)-1 {
		return false // no dot, or dot at start/end of domain
	}
	for i := range len(email) {
		if email[i] <= ' ' {
			return false // no spaces or control characters
		}
	}
	return true
}

// --- Response helpers ------------------------------------------------------

// staticHandler serves the embedded static/ directory under /static/ with a
// long cache lifetime. Content types are inferred from file extensions.
func staticHandler() http.Handler {
	files := http.FileServerFS(staticFS)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "max-age=3600")
		files.ServeHTTP(w, r)
	})
}
