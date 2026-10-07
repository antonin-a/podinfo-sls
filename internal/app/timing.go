package app

import (
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// processStart is taken when the package is initialised, which is as close to
// the process start as Go code can get.
var processStart = time.Now()

// kernelUptimeAtStart is the kernel uptime when the process started, read from
// /proc/uptime. Inside a freshly booted micro-VM it is the time the VM took to
// boot and launch this process; on a shared kernel it is the host uptime and
// says nothing about this instance. Nil when unreadable (not Linux).
var kernelUptimeAtStart = readKernelUptime()

// aheadOfTrafficThreshold: when the first request arrives later than this
// after the instance became ready, the platform started the instance before
// any request was waiting (at deploy, or to keep capacity), so that gap is
// idle time and not part of a cold start.
const aheadOfTrafficThreshold = 5 * time.Second

// vmBootThreshold separates a dedicated, just-booted kernel from a long-lived
// shared one.
const vmBootThreshold = 120 * time.Second

func readKernelUptime() *time.Duration {
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return nil
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return nil
	}
	secs, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return nil
	}
	d := time.Duration(secs * float64(time.Second))
	return &d
}

// startupClock records when the server became ready and when the first
// request arrived, as Unix nanoseconds (0 = not yet).
type startupClock struct {
	readyAt        atomic.Int64
	firstRequestAt atomic.Int64
}

// MarkReady records that the listener is open and requests can be accepted.
func (a *App) MarkReady() { a.clock.readyAt.CompareAndSwap(0, time.Now().UnixNano()) }

func (a *App) markRequest(t time.Time) { a.clock.firstRequestAt.CompareAndSwap(0, t.UnixNano()) }

// StartupInfo is the instance startup timeline exposed on /api/info and the
// page. Every field is nullable: a step that cannot be measured is null.
type StartupInfo struct {
	KernelBootToProcessMs *int64   `json:"kernelBootToProcessMs"`
	KernelUptimeSeconds   *float64 `json:"kernelUptimeSeconds"`
	DedicatedKernel       bool     `json:"dedicatedKernel"`
	ProcessToReadyMs      *int64   `json:"processToReadyMs"`
	ReadyToFirstRequestMs *int64   `json:"readyToFirstRequestMs"`
	FirstRequestAt        string   `json:"firstRequestAt,omitempty"`
	// StartedAheadOfTraffic is true when the first request came long after
	// the instance was ready: the instance was not started for it.
	StartedAheadOfTraffic bool `json:"startedAheadOfTraffic"`
	// InstanceColdStartMs sums what the instance itself can see of a cold
	// start: VM boot to process start, process start to ready, and ready to
	// first request when that request is the one that woke the instance.
	InstanceColdStartMs *int64 `json:"instanceColdStartMs"`
}

func ms(d time.Duration) *int64 { v := d.Milliseconds(); return &v }

func (a *App) startupInfo() StartupInfo {
	var s StartupInfo
	if kernelUptimeAtStart != nil {
		secs := kernelUptimeAtStart.Seconds()
		s.KernelUptimeSeconds = &secs
		if *kernelUptimeAtStart < vmBootThreshold {
			s.DedicatedKernel = true
			s.KernelBootToProcessMs = ms(*kernelUptimeAtStart)
		}
	}
	ready := a.clock.readyAt.Load()
	if ready != 0 {
		s.ProcessToReadyMs = ms(time.Unix(0, ready).Sub(processStart))
	}
	if first := a.clock.firstRequestAt.Load(); first != 0 {
		t := time.Unix(0, first)
		s.FirstRequestAt = t.UTC().Format(time.RFC3339Nano)
		if ready != 0 {
			gap := t.Sub(time.Unix(0, ready))
			s.ReadyToFirstRequestMs = ms(gap)
			s.StartedAheadOfTraffic = gap > aheadOfTrafficThreshold
		}
	}
	if s.ProcessToReadyMs != nil {
		total := *s.ProcessToReadyMs
		if s.KernelBootToProcessMs != nil {
			total += *s.KernelBootToProcessMs
		}
		if s.ReadyToFirstRequestMs != nil && !s.StartedAheadOfTraffic {
			total += *s.ReadyToFirstRequestMs
		}
		s.InstanceColdStartMs = &total
	}
	return s
}
