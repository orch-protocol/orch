package scale

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/orch-protocol/orch/internal/config"
	orchpb "github.com/orch-protocol/orch/internal/pb"
)

type NodeMetrics struct {
	NodeID     string
	CpuUsage   float32
	MemUsage   float32
	Goroutines uint32
	LastSeen   int64
}

type MetricsProvider interface {
	AliveNodeMetrics() []NodeMetrics
	ServiceCount(service string) int
}

type SelfProvider func() *orchpb.NodeId

type ScaleDecisionCallback func(signal *orchpb.ScaleSignal)

type ManagedProcess struct {
	Cmd     *exec.Cmd
	Pid     int
	Started time.Time
}

type ScaleManager struct {
	cfg       *config.Config
	self      SelfProvider
	provider  MetricsProvider
	callback  ScaleDecisionCallback
	lastScale time.Time
	processes []*ManagedProcess
	mu        sync.Mutex
}

func NewScaleManager(cfg *config.Config, self SelfProvider, provider MetricsProvider, callback ScaleDecisionCallback) *ScaleManager {
	return &ScaleManager{
		cfg:      cfg,
		self:     self,
		provider: provider,
		callback: callback,
	}
}

func (s *ScaleManager) Start(ctx context.Context) {
	if s.cfg == nil {
		return
	}
	if s.cfg.ScaleCommand == "" {
		log.Printf("scale manager disabled: ORCH_SCALE_CMD not configured")
		return
	}
	if s.provider == nil || s.self == nil {
		log.Printf("scale manager disabled: missing provider or self callback")
		return
	}

	interval := s.cfg.ScaleInterval
	if interval <= 0 {
		interval = 60 * time.Second
	}

	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.checkScale(ctx)
			}
		}
	}()
}

func (s *ScaleManager) checkScale(ctx context.Context) {
	self := s.self()
	if self == nil {
		return
	}
	if !self.IsLeader {
		return
	}

	if time.Since(s.lastScale) < s.cfg.ScaleInterval {
		return
	}

	// First, check desired count regardless of metrics
	if s.cfg.DesiredCount > 0 {
		targetService := s.cfg.ScaleService
		if targetService == "" {
			targetService = self.Service
		}

		currentCount := s.provider.ServiceCount(targetService)
		if currentCount < int(s.cfg.DesiredCount) {
			log.Printf("scale manager: service '%s' count (%d) below desired (%d), launching...", targetService, currentCount, s.cfg.DesiredCount)
			if err := s.launchProcess(ctx); err != nil {
				log.Printf("scale executor failed: %v", err)
			} else {
				s.lastScale = time.Now()
			}
			return
		}
		// Scale in if significantly above desired (optional, let's keep it safe)
	}

	metrics := s.provider.AliveNodeMetrics()
	if len(metrics) == 0 {
		return
	}

	targetService := s.cfg.ScaleService
	if targetService == "" {
		targetService = self.Service
	}

	var avgCPU, avgMem float32
	for _, m := range metrics {
		avgCPU += m.CpuUsage
		avgMem += m.MemUsage
	}
	avgCPU /= float32(len(metrics))
	avgMem /= float32(len(metrics))

	if avgCPU >= s.cfg.ScaleCPUThreshold || avgMem >= s.cfg.ScaleMemThreshold {
		signal := &orchpb.ScaleSignal{
			Direction: orchpb.ScaleSignal_OUT,
			Service:   targetService,
			Delta:     s.cfg.ScaleDelta,
			Reason:    fmt.Sprintf("cpu=%.2f mem=%.2f", avgCPU, avgMem),
		}
		if s.callback != nil {
			s.callback(signal)
		}
		if err := s.launchProcess(ctx); err != nil {
			log.Printf("scale executor failed: %v", err)
			return
		}
		s.lastScale = time.Now()
		log.Printf("scale out triggered: avg_cpu=%.2f avg_mem=%.2f", avgCPU, avgMem)
		return
	}

	if avgCPU <= s.cfg.ScaleCPUThreshold/2 && avgMem <= s.cfg.ScaleMemThreshold/2 && len(metrics) > 1 {
		// Only scale in if we are ABOVE desired count (if set) for the TARGET service
		if s.cfg.DesiredCount > 0 && s.provider.ServiceCount(targetService) <= int(s.cfg.DesiredCount) {
			return
		}

		signal := &orchpb.ScaleSignal{
			Direction: orchpb.ScaleSignal_IN,
			Service:   targetService,
			Delta:     s.cfg.ScaleDelta,
			Reason:    fmt.Sprintf("cpu=%.2f mem=%.2f", avgCPU, avgMem),
		}
		if s.callback != nil {
			s.callback(signal)
		}
		if err := s.stopProcess(ctx); err != nil {
			log.Printf("scale executor failed to stop process: %v", err)
			return
		}
		log.Printf("scale in triggered: avg_cpu=%.2f avg_mem=%.2f", avgCPU, avgMem)
		s.lastScale = time.Now()
	}
}

func (s *ScaleManager) parseScaleCommand() []string {
	cmd := s.cfg.ScaleCommand
	if cmd == "" {
		return nil
	}
	// Simple env var substitution
	cmd = strings.ReplaceAll(cmd, "$ORCH_ADDR", s.cfg.Addr)
	cmd = strings.ReplaceAll(cmd, "$ORCH_SERVICE", s.cfg.Service)
	cmd = strings.ReplaceAll(cmd, "$ORCH_CLUSTER_TOKEN", fmt.Sprintf("%d", s.cfg.ClusterToken))
	return strings.Fields(cmd)
}

func (s *ScaleManager) launchProcess(ctx context.Context) error {
	cmdStr := s.cfg.ScaleCommand
	if cmdStr == "" {
		return fmt.Errorf("no scale command configured")
	}

	// Support simple variable substitution
	cmdStr = strings.ReplaceAll(cmdStr, "$ORCH_ADDR", s.cfg.Addr)
	cmdStr = strings.ReplaceAll(cmdStr, "$ORCH_SERVICE", s.cfg.Service)
	cmdStr = strings.ReplaceAll(cmdStr, "$ORCH_CLUSTER_TOKEN", fmt.Sprintf("%d", s.cfg.ClusterToken))

	// Execute through shell to support environment variables and backgrounding (&)
	cmd := exec.CommandContext(ctx, "sh", "-c", cmdStr)
	
	// CRITICAL: Inherit parent environment so the child can find binaries and use SEEDS
	cmd.Env = os.Environ()
	// Add/Overwrite SEEDS with the leader's own address as a fallback/primary join point
	cmd.Env = append(cmd.Env, fmt.Sprintf("ORCH_SEEDS=%s", s.cfg.Addr))

	if err := cmd.Start(); err != nil {
		return err
	}
	proc := &ManagedProcess{
		Cmd:     cmd,
		Pid:     cmd.Process.Pid,
		Started: time.Now(),
	}
	s.mu.Lock()
	s.processes = append(s.processes, proc)
	s.mu.Unlock()
	log.Printf("scale executor launched process pid=%d", proc.Pid)
	// Wait for NODE_JOIN or timeout
	time.Sleep(5 * time.Second) // Simplified: assume join within 5s
	return nil
}

func (s *ScaleManager) stopProcess(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.processes) == 0 {
		return fmt.Errorf("no managed processes to stop")
	}
	// Stop the most recently started process
	proc := s.processes[len(s.processes)-1]
	if err := proc.Cmd.Process.Signal(syscall.SIGTERM); err != nil {
		return err
	}
	// Wait for graceful shutdown
	done := make(chan error, 1)
	go func() {
		done <- proc.Cmd.Wait()
	}()
	select {
	case err := <-done:
		log.Printf("scale executor stopped process pid=%d, err=%v", proc.Pid, err)
	case <-time.After(10 * time.Second):
		if err := proc.Cmd.Process.Kill(); err != nil {
			log.Printf("scale executor failed to kill process pid=%d: %v", proc.Pid, err)
		}
	}
	// Remove from list
	s.processes = s.processes[:len(s.processes)-1]
	return nil
}
