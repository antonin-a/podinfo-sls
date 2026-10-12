package app

import (
	"fmt"
	"net/http"
)

// handleFavicon serves a small SVG icon in the revision colour, under both
// /favicon.ico and /favicon.svg, so a browser left open on the page never
// produces 404s that a platform could count as errors.
func (a *App) handleFavicon(w http.ResponseWriter, r *http.Request) {
	svg := fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">`+
		`<rect width="32" height="32" rx="7" fill="%s"/>`+
		`<path d="M9 22 16 8l7 14z" fill="%s"/></svg>`, a.cfg.Color, contrastColor(a.cfg.Color))
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write([]byte(svg))
}

// handleRobots keeps crawlers away from the demo and answers 200.
func (a *App) handleRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write([]byte("User-agent: *\nDisallow: /\n"))
}
