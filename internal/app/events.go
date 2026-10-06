package app

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync"
	"time"
)

// maxEventBody bounds what a single CloudEvent may carry.
const maxEventBody = 1 << 20

// maxEventPreview bounds how much of the data payload is kept in memory.
const maxEventPreview = 2048

// Event is the subset of a CloudEvent we keep for the demo.
type Event struct {
	ID          string `json:"id"`
	Type        string `json:"type"`
	Source      string `json:"source"`
	Subject     string `json:"subject,omitempty"`
	Time        string `json:"time,omitempty"`
	Mode        string `json:"mode"`
	ContentType string `json:"dataContentType,omitempty"`
	DataSize    int    `json:"dataSize"`
	DataPreview string `json:"dataPreview,omitempty"`
	ReceivedAt  string `json:"receivedAt"`
	InstanceID  string `json:"instanceId"`
}

// eventRing keeps the last N events, newest first on read.
type eventRing struct {
	mu   sync.Mutex
	buf  []Event
	next int
	full bool
}

func newEventRing(n int) *eventRing {
	return &eventRing{buf: make([]Event, n)}
}

func (r *eventRing) add(e Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf[r.next] = e
	r.next = (r.next + 1) % len(r.buf)
	if r.next == 0 {
		r.full = true
	}
}

func (r *eventRing) list() []Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := r.next
	if r.full {
		n = len(r.buf)
	}
	out := make([]Event, 0, n)
	// Walk backwards from the most recent slot.
	for i := 0; i < n; i++ {
		idx := (r.next - 1 - i + len(r.buf)) % len(r.buf)
		out = append(out, r.buf[idx])
	}
	return out
}

// structuredEvent is the JSON envelope of CloudEvents structured mode.
type structuredEvent struct {
	ID              string          `json:"id"`
	Type            string          `json:"type"`
	Source          string          `json:"source"`
	Subject         string          `json:"subject"`
	Time            string          `json:"time"`
	DataContentType string          `json:"datacontenttype"`
	Data            json.RawMessage `json:"data"`
	DataBase64      string          `json:"data_base64"`
}

func (a *App) handleEventsPost(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEventBody))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "body too large or unreadable"})
		return
	}

	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	ev := Event{
		ReceivedAt: time.Now().UTC().Format(time.RFC3339Nano),
		InstanceID: a.inst.ID,
	}

	var data []byte
	if mediaType == "application/cloudevents+json" {
		var se structuredEvent
		if err := json.Unmarshal(body, &se); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid structured CloudEvent: " + err.Error()})
			return
		}
		ev.Mode = "structured"
		ev.ID, ev.Type, ev.Source, ev.Subject, ev.Time = se.ID, se.Type, se.Source, se.Subject, se.Time
		ev.ContentType = se.DataContentType
		switch {
		case len(se.Data) > 0:
			data = se.Data
		case se.DataBase64 != "":
			data = []byte(se.DataBase64)
		}
	} else {
		ev.Mode = "binary"
		ev.ID = r.Header.Get("ce-id")
		ev.Type = r.Header.Get("ce-type")
		ev.Source = r.Header.Get("ce-source")
		ev.Subject = r.Header.Get("ce-subject")
		ev.Time = r.Header.Get("ce-time")
		ev.ContentType = r.Header.Get("Content-Type")
		data = body
	}

	if ev.ID == "" {
		ev.ID = "generated-" + randomID(12)
	}
	if ev.Type == "" {
		ev.Type = "unknown"
	}
	if ev.Source == "" {
		ev.Source = "unknown"
	}
	ev.DataSize = len(data)
	ev.DataPreview = preview(data)

	a.events.add(ev)

	a.log.Info("event received",
		"id", ev.ID,
		"type", ev.Type,
		"source", ev.Source,
		"subject", ev.Subject,
		"time", ev.Time,
		"mode", ev.Mode,
		"dataSize", ev.DataSize,
		"instanceId", a.inst.ID,
		"failOnPurpose", a.cfg.FailEvents,
	)

	if a.cfg.FailEvents {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"error": "failing on purpose",
			"id":    ev.ID,
		})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"received":   ev.ID,
		"type":       ev.Type,
		"instanceId": a.inst.ID,
	})
}

func (a *App) handleEventsGet(w http.ResponseWriter, r *http.Request) {
	list := a.events.list()
	writeJSON(w, http.StatusOK, map[string]any{
		"count":      len(list),
		"capacity":   len(a.events.buf),
		"instanceId": a.inst.ID,
		"events":     list,
	})
}

func preview(b []byte) string {
	s := strings.ToValidUTF8(string(b), "?")
	if len(s) > maxEventPreview {
		return s[:maxEventPreview] + "..."
	}
	return s
}
