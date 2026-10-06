// Command podinfo-sls is a small web application that makes serverless
// runtime behaviour visible: cold starts, instance identity, revisions
// driven by environment variables, probes, chaos endpoints, SSE and a
// CloudEvents receiver. It is inspired by stefanprodan/podinfo.
package main

import (
	"context"
	"embed"
	"errors"
	"flag"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/antonin-a/podinfo-sls/internal/app"
)

// version is overridden at build time with -ldflags "-X main.version=<v>".
var version = "dev"

//go:embed ui
var uiFiles embed.FS

func main() {
	portFlag := flag.String("port", "", "port to listen on (overrides the PORT environment variable)")
	flag.Parse()

	cfg := app.LoadConfig(version)
	if *portFlag != "" {
		cfg.Port = *portFlag
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(logger)

	ui, err := fs.Sub(uiFiles, "ui")
	if err != nil {
		logger.Error("cannot load embedded ui", "error", err)
		os.Exit(1)
	}

	a, err := app.New(cfg, ui, logger)
	if err != nil {
		logger.Error("cannot initialise application", "error", err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           a.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout on purpose: /delay and /stream are long-lived by design.
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.ListenAndServe()
	}()

	logger.Info("instance started",
		"port", cfg.Port,
		"version", cfg.Version,
		"revisionLabel", cfg.RevisionLabel,
		"color", cfg.Color,
		"instanceId", a.InstanceID(),
		"hostname", a.Hostname(),
	)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	case <-ctx.Done():
		stop()
		logger.Info("SIGTERM received, draining",
			"instanceId", a.InstanceID(),
			"timeoutSeconds", 10,
			"requestsServed", a.RequestsServed(),
		)
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			logger.Warn("drain incomplete, forcing close", "error", err)
			_ = srv.Close()
		}
	}

	logger.Info("instance stopped",
		"instanceId", a.InstanceID(),
		"uptimeSeconds", int64(a.Uptime().Seconds()),
		"requestsServed", a.RequestsServed(),
	)
}
