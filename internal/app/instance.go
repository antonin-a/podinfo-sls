package app

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"sync/atomic"
	"time"
)

// coldStartWindow is how long after boot a request is considered to have
// hit a freshly started instance.
const coldStartWindow = 5 * time.Second

// Instance describes the running process. One Instance exists per container.
type Instance struct {
	Hostname  string
	ID        string
	StartedAt time.Time
	requests  atomic.Int64
}

func newInstance() *Instance {
	host, err := os.Hostname()
	if err != nil || host == "" || host == "(none)" {
		host = "not set by the platform"
	}
	return &Instance{
		Hostname:  host,
		ID:        randomID(8),
		StartedAt: processStart,
	}
}

func randomID(n int) string {
	b := make([]byte, (n+1)/2)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%0*x", n, time.Now().UnixNano())[:n]
	}
	return hex.EncodeToString(b)[:n]
}

// Uptime is the time elapsed since the process started.
func (i *Instance) Uptime() time.Duration { return time.Since(i.StartedAt) }

// ColdStart reports whether the instance is still inside the cold start window.
func (i *Instance) ColdStart() bool { return i.Uptime() < coldStartWindow }

// Requests returns the number of requests served so far.
func (i *Instance) Requests() int64 { return i.requests.Load() }

func (i *Instance) countRequest() int64 { return i.requests.Add(1) }

// humanDuration renders a duration the way a person reads it on stage.
func humanDuration(d time.Duration) string {
	if d < time.Second {
		return fmt.Sprintf("%dms", d.Milliseconds())
	}
	d = d.Round(time.Second)
	days := d / (24 * time.Hour)
	d -= days * 24 * time.Hour
	h := d / time.Hour
	d -= h * time.Hour
	m := d / time.Minute
	s := d - m*time.Minute
	switch {
	case days > 0:
		return fmt.Sprintf("%dd %dh %dm", days, h, m)
	case h > 0:
		return fmt.Sprintf("%dh %02dm %02ds", h, m, int(s.Seconds()))
	case m > 0:
		return fmt.Sprintf("%dm %02ds", m, int(s.Seconds()))
	default:
		return fmt.Sprintf("%ds", int(s.Seconds()))
	}
}
