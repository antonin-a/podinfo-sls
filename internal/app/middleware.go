package app

import (
	"bufio"
	"errors"
	"net"
	"net/http"
	"time"
)

// statusWriter records the status code and keeps Flush and Hijack reachable
// so Server-Sent Events still work through the middleware.
type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusWriter) WriteHeader(code int) {
	if !w.wrote {
		w.status = code
		w.wrote = true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.status = http.StatusOK
		w.wrote = true
	}
	return w.ResponseWriter.Write(b)
}

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, errors.New("hijack not supported")
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// instrument adds identity headers, counts the request and writes one JSON
// log line once the handler returns.
func (a *App) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		a.inst.countRequest()

		h := w.Header()
		h.Set("X-Instance-Id", a.inst.ID)
		h.Set("X-Revision-Label", a.cfg.RevisionLabel)
		h.Set("X-Served-By", "podinfo-sls/"+a.cfg.Version)

		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)

		logFn := a.log.Info
		if isProbe(r.URL.Path) {
			logFn = a.log.Debug
		}
		logFn("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", sw.status,
			"durationMs", float64(time.Since(start).Microseconds())/1000.0,
			"instanceId", a.inst.ID,
			"revisionLabel", a.cfg.RevisionLabel,
			"remote", r.RemoteAddr,
			"userAgent", shortUA(r.UserAgent()),
		)
	})
}

func isProbe(path string) bool {
	return path == "/healthz" || path == "/readyz"
}

func shortUA(ua string) string {
	const max = 48
	if len(ua) > max {
		return ua[:max] + "..."
	}
	return ua
}
