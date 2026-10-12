// Package app contains the HTTP handlers, instance state and logging
// middleware of podinfo-sls.
package app

import (
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

// App is the wired application: configuration, instance state and handlers.
type App struct {
	cfg    Config
	inst   *Instance
	log    *slog.Logger
	tmpl   *template.Template
	static fs.FS

	ready atomic.Bool

	events *eventRing

	memMu   sync.Mutex
	memHeld [][]byte
}

// New builds an App from the configuration and the embedded UI files.
func New(cfg Config, ui fs.FS, logger *slog.Logger) (*App, error) {
	if logger == nil {
		logger = slog.Default()
	}
	tmpl, err := template.New("index.html.tmpl").ParseFS(ui, "index.html.tmpl")
	if err != nil {
		return nil, fmt.Errorf("parse template: %w", err)
	}
	a := &App{
		cfg:    cfg,
		inst:   newInstance(),
		log:    logger,
		tmpl:   tmpl,
		static: ui,
		events: newEventRing(20),
	}
	a.ready.Store(true)
	return a, nil
}

// InstanceID returns the short random id of this instance.
func (a *App) InstanceID() string { return a.inst.ID }

// Hostname returns the instance hostname.
func (a *App) Hostname() string { return a.inst.Hostname }

// Uptime returns the instance uptime.
func (a *App) Uptime() time.Duration { return a.inst.Uptime() }

// RequestsServed returns the number of requests handled so far.
func (a *App) RequestsServed() int64 { return a.inst.Requests() }

// Handler returns the routed and instrumented HTTP handler.
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", a.handleIndex)
	mux.HandleFunc("GET /style.css", a.handleStyle)
	// Browsers ask for these on their own: answer them so they never show up
	// as 404s in the platform error rate.
	mux.HandleFunc("GET /favicon.ico", a.handleFavicon)
	mux.HandleFunc("GET /favicon.svg", a.handleFavicon)
	mux.HandleFunc("GET /robots.txt", a.handleRobots)

	mux.HandleFunc("GET /api/info", a.handleInfo)
	mux.HandleFunc("GET /api/env", a.handleEnv)

	mux.HandleFunc("GET /healthz", a.handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	mux.HandleFunc("POST /readyz/disable", a.handleReadyzDisable)
	mux.HandleFunc("POST /readyz/enable", a.handleReadyzEnable)

	mux.HandleFunc("GET /delay/{seconds}", a.handleDelay)
	mux.HandleFunc("GET /status/{code}", a.handleStatus)
	mux.HandleFunc("GET /panic", a.handlePanic)

	mux.HandleFunc("GET /burn/cpu", a.handleBurnCPU)
	mux.HandleFunc("GET /burn/mem", a.handleBurnMem)
	mux.HandleFunc("GET /burn/mem/release", a.handleBurnMemRelease)

	mux.HandleFunc("GET /stream", a.handleStream)

	mux.HandleFunc("POST /events", a.handleEventsPost)
	mux.HandleFunc("GET /events", a.handleEventsGet)

	mux.HandleFunc("/", a.handleNotFound)

	return a.instrument(mux)
}
