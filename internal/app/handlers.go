package app

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Caps for the chaos endpoints so a typo on stage cannot take the demo down.
const (
	maxDelaySeconds   = 60
	maxBurnCPUSeconds = 30
	maxBurnMemMiB     = 2048
	maxStreamSeconds  = 300
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// ---- UI ------------------------------------------------------------------

type pageData struct {
	Color         string
	TextColor     string
	Message       string
	Logo          string
	Version       string
	RevisionLabel string
	Hostname      string
	InstanceID    string
	StartedAt     string
	UptimeHuman   string
	Requests      int64
	ColdStart     bool
	GOOS          string
	GOARCH        string
	GoVersion     string
	NumCPU        int
	Port          string
	Refresh       bool
	FailEvents    bool
	Startup       StartupInfo
}

func (a *App) handleIndex(w http.ResponseWriter, r *http.Request) {
	d := pageData{
		Color:         a.cfg.Color,
		TextColor:     contrastColor(a.cfg.Color),
		Message:       a.cfg.Message,
		Logo:          a.cfg.Logo,
		Version:       a.cfg.Version,
		RevisionLabel: a.cfg.RevisionLabel,
		Hostname:      a.inst.Hostname,
		InstanceID:    a.inst.ID,
		StartedAt:     a.inst.StartedAt.UTC().Format(time.RFC3339),
		UptimeHuman:   humanDuration(a.inst.Uptime()),
		Requests:      a.inst.Requests(),
		ColdStart:     a.inst.ColdStart(),
		GOOS:          runtime.GOOS,
		GOARCH:        runtime.GOARCH,
		GoVersion:     runtime.Version(),
		NumCPU:        runtime.NumCPU(),
		Port:          a.cfg.Port,
		Refresh:       r.URL.Query().Get("refresh") == "1",
		FailEvents:    a.cfg.FailEvents,
		Startup:       a.startupInfo(),
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := a.tmpl.Execute(w, d); err != nil {
		a.log.Error("render index", "error", err)
	}
}

func (a *App) handleStyle(w http.ResponseWriter, r *http.Request) {
	b, err := readStatic(a, "style.css")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "stylesheet unavailable"})
		return
	}
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=60")
	_, _ = w.Write(b)
}

func readStatic(a *App, name string) ([]byte, error) {
	f, err := a.static.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var sb strings.Builder
	buf := make([]byte, 32*1024)
	for {
		n, err := f.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	return []byte(sb.String()), nil
}

// contrastColor picks black or white text for a hex background colour.
func contrastColor(hexColor string) string {
	h := strings.TrimPrefix(strings.TrimSpace(hexColor), "#")
	if len(h) == 3 {
		h = string([]byte{h[0], h[0], h[1], h[1], h[2], h[2]})
	}
	if len(h) != 6 {
		return "#FFFFFF"
	}
	v, err := strconv.ParseUint(h, 16, 32)
	if err != nil {
		return "#FFFFFF"
	}
	r := float64((v>>16)&0xFF) / 255
	g := float64((v>>8)&0xFF) / 255
	b := float64(v&0xFF) / 255
	lum := 0.2126*r + 0.7152*g + 0.0722*b
	if lum > 0.6 {
		return "#0D1B2A"
	}
	return "#FFFFFF"
}

// ---- API -----------------------------------------------------------------

type infoResponse struct {
	Hostname       string      `json:"hostname"`
	InstanceID     string      `json:"instanceId"`
	Version        string      `json:"version"`
	RevisionLabel  string      `json:"revisionLabel"`
	Color          string      `json:"color"`
	Message        string      `json:"message"`
	StartedAt      string      `json:"startedAt"`
	UptimeSeconds  int64       `json:"uptimeSeconds"`
	RequestsServed int64       `json:"requestsServed"`
	ColdStart      bool        `json:"coldStart"`
	GOOS           string      `json:"goos"`
	GOARCH         string      `json:"goarch"`
	GoVersion      string      `json:"goVersion"`
	NumCPU         int         `json:"numCPU"`
	Port           string      `json:"port"`
	Startup        StartupInfo `json:"startup"`
}

func (a *App) handleInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, infoResponse{
		Hostname:       a.inst.Hostname,
		InstanceID:     a.inst.ID,
		Version:        a.cfg.Version,
		RevisionLabel:  a.cfg.RevisionLabel,
		Color:          a.cfg.Color,
		Message:        a.cfg.Message,
		StartedAt:      a.inst.StartedAt.UTC().Format(time.RFC3339),
		UptimeSeconds:  int64(a.inst.Uptime().Seconds()),
		RequestsServed: a.inst.Requests(),
		ColdStart:      a.inst.ColdStart(),
		GOOS:           runtime.GOOS,
		GOARCH:         runtime.GOARCH,
		GoVersion:      runtime.Version(),
		NumCPU:         runtime.NumCPU(),
		Port:           a.cfg.Port,
		Startup:        a.startupInfo(),
	})
}

type maskedSecret struct {
	Length   int    `json:"length"`
	SHA25612 string `json:"sha256_12"`
	Masked   bool   `json:"masked"`
}

type envEntry struct {
	Name  string `json:"name"`
	Value any    `json:"value"`
}

func (a *App) handleEnv(w http.ResponseWriter, r *http.Request) {
	entries := make([]envEntry, 0, 16)
	for _, kv := range os.Environ() {
		name, value, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if name != EnvPort && !strings.HasPrefix(name, "SLS_") {
			continue
		}
		if strings.HasPrefix(name, "SLS_SECRET_") {
			sum := sha256.Sum256([]byte(value))
			entries = append(entries, envEntry{Name: name, Value: maskedSecret{
				Length:   len(value),
				SHA25612: hex.EncodeToString(sum[:])[:12],
				Masked:   true,
			}})
			continue
		}
		entries = append(entries, envEntry{Name: name, Value: value})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })

	// Emit an object keyed by name while preserving the sorted order.
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	var sb strings.Builder
	sb.WriteString("{\n")
	for i, e := range entries {
		k, _ := json.Marshal(e.Name)
		v, _ := json.MarshalIndent(e.Value, "  ", "  ")
		sb.WriteString("  ")
		sb.Write(k)
		sb.WriteString(": ")
		sb.Write(v)
		if i < len(entries)-1 {
			sb.WriteString(",")
		}
		sb.WriteString("\n")
	}
	sb.WriteString("}\n")
	_, _ = w.Write([]byte(sb.String()))
}

// ---- Probes --------------------------------------------------------------

func (a *App) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *App) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !a.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"status": "not ready",
			"ready":  false,
			"hint":   "POST /readyz/enable to restore readiness",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "ready": true})
}

func (a *App) handleReadyzDisable(w http.ResponseWriter, r *http.Request) {
	a.ready.Store(false)
	a.log.Warn("readiness disabled on request", "instanceId", a.inst.ID)
	writeJSON(w, http.StatusOK, map[string]any{"status": "readiness disabled", "ready": false})
}

func (a *App) handleReadyzEnable(w http.ResponseWriter, r *http.Request) {
	a.ready.Store(true)
	a.log.Info("readiness enabled on request", "instanceId", a.inst.ID)
	writeJSON(w, http.StatusOK, map[string]any{"status": "readiness enabled", "ready": true})
}

// ---- Chaos ---------------------------------------------------------------

func (a *App) handleDelay(w http.ResponseWriter, r *http.Request) {
	secs, err := strconv.ParseFloat(r.PathValue("seconds"), 64)
	if err != nil || secs < 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "seconds must be a non-negative number"})
		return
	}
	if secs > maxDelaySeconds {
		secs = maxDelaySeconds
	}
	d := time.Duration(secs * float64(time.Second))
	select {
	case <-time.After(d):
	case <-r.Context().Done():
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"delay": secs, "instanceId": a.inst.ID})
}

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	code, err := strconv.Atoi(r.PathValue("code"))
	if err != nil || code < 100 || code > 599 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "code must be between 100 and 599"})
		return
	}
	writeJSON(w, code, map[string]any{"status": code, "instanceId": a.inst.ID})
}

func (a *App) handlePanic(w http.ResponseWriter, r *http.Request) {
	a.log.Error("panic requested, exiting with code 255",
		"instanceId", a.inst.ID,
		"remote", r.RemoteAddr,
		"uptimeSeconds", int64(a.inst.Uptime().Seconds()),
	)
	_ = os.Stdout.Sync()
	_ = os.Stderr.Sync()
	os.Exit(255)
}

func clampQueryInt(r *http.Request, key string, def, max int) int {
	v := r.URL.Query().Get(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return def
	}
	if n > max {
		return max
	}
	return n
}

func (a *App) handleBurnCPU(w http.ResponseWriter, r *http.Request) {
	secs := clampQueryInt(r, "s", 1, maxBurnCPUSeconds)
	n := runtime.NumCPU()
	deadline := time.Now().Add(time.Duration(secs) * time.Second)
	ctx := r.Context()

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			x := 0.0
			for time.Now().Before(deadline) {
				for k := 0; k < 1_000_000; k++ {
					x += float64(k) * 1.000001
				}
				if ctx.Err() != nil {
					return
				}
			}
			_ = x
		}()
	}
	wg.Wait()
	writeJSON(w, http.StatusOK, map[string]any{"seconds": secs, "goroutines": n, "instanceId": a.inst.ID})
}

func (a *App) handleBurnMem(w http.ResponseWriter, r *http.Request) {
	mb := clampQueryInt(r, "mb", 64, maxBurnMemMiB)
	const pageSize = 4096
	block := make([]byte, mb<<20)
	for i := 0; i < len(block); i += pageSize {
		block[i] = byte(i)
	}
	a.memMu.Lock()
	a.memHeld = append(a.memHeld, block)
	held := a.heldMiBLocked()
	a.memMu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{"allocatedMiB": mb, "heldMiB": held, "instanceId": a.inst.ID})
}

func (a *App) handleBurnMemRelease(w http.ResponseWriter, r *http.Request) {
	a.memMu.Lock()
	released := a.heldMiBLocked()
	a.memHeld = nil
	a.memMu.Unlock()
	runtime.GC()
	debug.FreeOSMemory()
	writeJSON(w, http.StatusOK, map[string]any{"releasedMiB": released, "heldMiB": 0, "instanceId": a.inst.ID})
}

func (a *App) heldMiBLocked() int {
	total := 0
	for _, b := range a.memHeld {
		total += len(b) >> 20
	}
	return total
}

// ---- Server-Sent Events --------------------------------------------------

func (a *App) handleStream(w http.ResponseWriter, r *http.Request) {
	secs := clampQueryInt(r, "s", 10, maxStreamSeconds)

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	rc := http.NewResponseController(w)
	_, _ = fmt.Fprintf(w, ": connected to %s\n\n", a.inst.ID)
	_ = rc.Flush()

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for tick := 1; tick <= secs; tick++ {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
		}
		payload, _ := json.Marshal(map[string]any{
			"tick":          tick,
			"instanceId":    a.inst.ID,
			"uptimeSeconds": int64(a.inst.Uptime().Seconds()),
		})
		if _, err := fmt.Fprintf(w, "id: %d\nevent: tick\ndata: %s\n\n", tick, payload); err != nil {
			return
		}
		if err := rc.Flush(); err != nil {
			return
		}
	}
	_, _ = fmt.Fprint(w, "event: end\ndata: {\"done\":true}\n\n")
	_ = rc.Flush()
}

// ---- Fallback ------------------------------------------------------------

func (a *App) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, map[string]any{
		"error":      "not found",
		"path":       r.URL.Path,
		"instanceId": a.inst.ID,
	})
}
