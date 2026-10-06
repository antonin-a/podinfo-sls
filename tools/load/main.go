// Command load sends HTTP requests at a fixed rate and reports latency
// percentiles, status codes and the "color" field of JSON responses.
//
// It only uses the standard library and lives in its own Go module so it does
// not pollute the application module.
//
// Usage:
//
//	go run ./tools/load -url https://demo.example -rps 20 -duration 60s -path /api/info
//
// Flags:
//
//	-url       base URL of the service (required)
//	-path      request path (default /api/info)
//	-rps       target requests per second (default 20)
//	-duration  total run time (default 60s)
//	-workers   concurrent workers draining the fixed-rate queue (default 10)
//	-timeout   per-request timeout (default 30s)
//	-report    reporting interval (default 5s)
//
// Every report interval it prints the achieved req/s, p50/p95/p99 latency in
// ms, a status histogram and a colour histogram for the interval; a cumulative
// summary is printed at exit. Exit code is 1 when the URL is missing or the
// run could not start.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type sample struct {
	latency time.Duration
	status  int
	color   string
}

type stats struct {
	mu        sync.Mutex
	latencies []time.Duration
	statuses  map[string]int
	colors    map[string]int
	count     int
}

func newStats() *stats {
	return &stats{statuses: map[string]int{}, colors: map[string]int{}}
}

func (s *stats) add(sm sample) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.count++
	s.latencies = append(s.latencies, sm.latency)
	key := "err"
	if sm.status > 0 {
		key = fmt.Sprintf("%d", sm.status)
	}
	s.statuses[key]++
	if sm.color != "" {
		s.colors[sm.color]++
	}
}

// snapshot returns a copy and, when reset is true, clears the interval data.
func (s *stats) snapshot(reset bool) *stats {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := newStats()
	out.count = s.count
	out.latencies = append([]time.Duration(nil), s.latencies...)
	for k, v := range s.statuses {
		out.statuses[k] = v
	}
	for k, v := range s.colors {
		out.colors[k] = v
	}
	if reset {
		s.count = 0
		s.latencies = s.latencies[:0]
		s.statuses = map[string]int{}
		s.colors = map[string]int{}
	}
	return out
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(float64(len(sorted)-1) * p)
	return sorted[idx]
}

func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func histogram(m map[string]int, total int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		pct := 0.0
		if total > 0 {
			pct = 100 * float64(m[k]) / float64(total)
		}
		parts = append(parts, fmt.Sprintf("%s=%d (%.0f%%)", k, m[k], pct))
	}
	if len(parts) == 0 {
		return "-"
	}
	return strings.Join(parts, " ")
}

func (s *stats) line(label string, elapsed time.Duration) string {
	sorted := append([]time.Duration(nil), s.latencies...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	rate := 0.0
	if elapsed > 0 {
		rate = float64(s.count) / elapsed.Seconds()
	}
	out := fmt.Sprintf("%-8s %6.1f req/s  p50 %6.0f ms  p95 %6.0f ms  p99 %6.0f ms  status[%s]",
		label, rate, ms(percentile(sorted, 0.50)), ms(percentile(sorted, 0.95)), ms(percentile(sorted, 0.99)),
		histogram(s.statuses, s.count))
	if len(s.colors) > 0 {
		out += fmt.Sprintf("  color[%s]", histogram(s.colors, s.count))
	}
	return out
}

func doRequest(ctx context.Context, client *http.Client, url string) sample {
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return sample{latency: time.Since(start)}
	}
	resp, err := client.Do(req)
	if err != nil {
		return sample{latency: time.Since(start)}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	sm := sample{latency: time.Since(start), status: resp.StatusCode}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json") {
		var payload map[string]any
		if json.Unmarshal(body, &payload) == nil {
			if c, ok := payload["color"].(string); ok {
				sm.color = c
			}
		}
	}
	return sm
}

func main() {
	baseURL := flag.String("url", "", "base URL of the service (required)")
	path := flag.String("path", "/api/info", "request path")
	rps := flag.Float64("rps", 20, "target requests per second")
	duration := flag.Duration("duration", 60*time.Second, "total run time")
	workers := flag.Int("workers", 10, "concurrent workers")
	timeout := flag.Duration("timeout", 30*time.Second, "per-request timeout")
	report := flag.Duration("report", 5*time.Second, "reporting interval")
	flag.Parse()

	if *baseURL == "" {
		fmt.Fprintln(os.Stderr, "load: -url is required")
		flag.Usage()
		os.Exit(1)
	}
	if *rps <= 0 || *workers <= 0 {
		fmt.Fprintln(os.Stderr, "load: -rps and -workers must be positive")
		os.Exit(1)
	}
	target := strings.TrimRight(*baseURL, "/") + *path

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Fprintln(os.Stderr, "\nload: interrupted, printing summary")
		cancel()
	}()

	client := &http.Client{
		Timeout: *timeout,
		Transport: &http.Transport{
			MaxIdleConns:        *workers * 2,
			MaxIdleConnsPerHost: *workers * 2,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	interval := newStats()
	total := newStats()
	jobs := make(chan struct{}, *workers*4)
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range jobs {
				sm := doRequest(ctx, client, target)
				interval.add(sm)
				total.add(sm)
			}
		}()
	}

	fmt.Printf("load: %s at %.1f req/s for %s with %d workers\n", target, *rps, *duration, *workers)
	start := time.Now()
	lastReport := start
	ticker := time.NewTicker(time.Duration(float64(time.Second) / *rps))
	reporter := time.NewTicker(*report)
	dropped := 0

loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case <-ticker.C:
			select {
			case jobs <- struct{}{}:
			default:
				dropped++ // workers saturated: the service is slower than the target rate
			}
		case now := <-reporter.C:
			snap := interval.snapshot(true)
			fmt.Printf("[%4.0fs] %s\n", now.Sub(start).Seconds(), snap.line("interval", now.Sub(lastReport)))
			lastReport = now
		}
	}
	ticker.Stop()
	reporter.Stop()
	close(jobs)
	wg.Wait()

	elapsed := time.Since(start)
	snap := total.snapshot(false)
	fmt.Println(strings.Repeat("-", 100))
	fmt.Printf("%s\n", snap.line("total", elapsed))
	fmt.Printf("elapsed %.1fs, %d requests, %d dropped (queue full)\n", elapsed.Seconds(), snap.count, dropped)
}
