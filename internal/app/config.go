package app

import (
	"log/slog"
	"os"
	"strings"
)

// Config holds every runtime setting. Each value has a default so the
// binary starts with no environment at all.
type Config struct {
	Port          string
	Color         string
	Message       string
	Logo          string
	RevisionLabel string
	Version       string
	FailEvents    bool
	LogLevel      slog.Level
}

// Environment variable names understood by the application.
const (
	EnvPort          = "PORT"
	EnvColor         = "SLS_UI_COLOR"
	EnvMessage       = "SLS_UI_MESSAGE"
	EnvLogo          = "SLS_UI_LOGO"
	EnvRevisionLabel = "SLS_REVISION_LABEL"
	EnvVersion       = "SLS_VERSION"
	EnvFailEvents    = "SLS_FAIL_EVENTS"
	EnvLogLevel      = "SLS_LOG_LEVEL"
)

// Defaults.
const (
	DefaultPort          = "9898"
	DefaultColor         = "#00AA55"
	DefaultMessage       = "Hello from the green revision"
	DefaultRevisionLabel = "rev-green"
)

// LoadConfig reads the environment. buildVersion is the value injected at
// build time; SLS_VERSION overrides it when set so that a revision can be
// relabelled without rebuilding.
func LoadConfig(buildVersion string) Config {
	if buildVersion == "" {
		buildVersion = "dev"
	}
	return Config{
		Port:          envOr(EnvPort, DefaultPort),
		Color:         envOr(EnvColor, DefaultColor),
		Message:       envOr(EnvMessage, DefaultMessage),
		Logo:          envOr(EnvLogo, ""),
		RevisionLabel: envOr(EnvRevisionLabel, DefaultRevisionLabel),
		Version:       envOr(EnvVersion, buildVersion),
		FailEvents:    envBool(EnvFailEvents, false),
		LogLevel:      envLevel(EnvLogLevel, slog.LevelInfo),
	}
}

func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return def
}

func envBool(key string, def bool) bool {
	v := strings.ToLower(envOr(key, ""))
	switch v {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

func envLevel(key string, def slog.Level) slog.Level {
	switch strings.ToLower(envOr(key, "")) {
	case "debug":
		return slog.LevelDebug
	case "info":
		return slog.LevelInfo
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	}
	return def
}
