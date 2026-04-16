package config

import (
	"os"
	"testing"
	"time"
)

func TestNewConfigDefaults(t *testing.T) {
	orig := map[string]string{
		"ORCH_CLUSTER_TOKEN":      os.Getenv("ORCH_CLUSTER_TOKEN"),
		"ORCH_ADDR":               os.Getenv("ORCH_ADDR"),
		"ORCH_SEEDS":              os.Getenv("ORCH_SEEDS"),
		"ORCH_SERVICE":            os.Getenv("ORCH_SERVICE"),
		"ORCH_VERSION":            os.Getenv("ORCH_VERSION"),
		"ORCH_HEARTBEAT_INTERVAL": os.Getenv("ORCH_HEARTBEAT_INTERVAL"),
	}
	defer func() {
		for key, value := range orig {
			if value == "" {
				os.Unsetenv(key)
			} else {
				os.Setenv(key, value)
			}
		}
	}()

	os.Setenv("ORCH_CLUSTER_TOKEN", "1234")
	os.Unsetenv("ORCH_ADDR")
	os.Setenv("ORCH_SEEDS", " a.example:7946, b.example:7946 ")
	os.Setenv("ORCH_SERVICE", "payment")
	os.Unsetenv("ORCH_VERSION")
	os.Setenv("ORCH_HEARTBEAT_INTERVAL", "1500ms")

	cfg, err := NewConfig()
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if cfg.ClusterToken != 1234 {
		t.Fatalf("expected cluster token 1234, got %d", cfg.ClusterToken)
	}
	if cfg.Addr != "0.0.0.0:7946" {
		t.Fatalf("expected default addr, got %q", cfg.Addr)
	}
	if cfg.Service != "payment" {
		t.Fatalf("expected service payment, got %q", cfg.Service)
	}
	if cfg.Version != "0.0.1" {
		t.Fatalf("expected default version 0.0.1, got %q", cfg.Version)
	}
	if len(cfg.Seeds) != 2 || cfg.Seeds[0] != "a.example:7946" || cfg.Seeds[1] != "b.example:7946" {
		t.Fatalf("unexpected seeds: %#v", cfg.Seeds)
	}
	if cfg.HeartbeatInterval != 1500*time.Millisecond {
		t.Fatalf("expected heartbeat interval 1500ms, got %v", cfg.HeartbeatInterval)
	}
}

func TestNewConfigInvalidToken(t *testing.T) {
	orig := os.Getenv("ORCH_CLUSTER_TOKEN")
	defer func() {
		if orig == "" {
			os.Unsetenv("ORCH_CLUSTER_TOKEN")
		} else {
			os.Setenv("ORCH_CLUSTER_TOKEN", orig)
		}
	}()

	os.Setenv("ORCH_CLUSTER_TOKEN", "not-a-number")

	_, err := NewConfig()
	if err == nil {
		t.Fatal("expected error for invalid cluster token")
	}
}

func TestNewConfigDurationFallback(t *testing.T) {
	origToken := os.Getenv("ORCH_CLUSTER_TOKEN")
	origInterval := os.Getenv("ORCH_HEARTBEAT_INTERVAL")
	defer func() {
		if origToken == "" {
			os.Unsetenv("ORCH_CLUSTER_TOKEN")
		} else {
			os.Setenv("ORCH_CLUSTER_TOKEN", origToken)
		}
		if origInterval == "" {
			os.Unsetenv("ORCH_HEARTBEAT_INTERVAL")
		} else {
			os.Setenv("ORCH_HEARTBEAT_INTERVAL", origInterval)
		}
	}()

	os.Setenv("ORCH_CLUSTER_TOKEN", "4321")
	os.Setenv("ORCH_HEARTBEAT_INTERVAL", "invalid-duration")

	cfg, err := NewConfig()
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.HeartbeatInterval != 1000*time.Millisecond {
		t.Fatalf("expected default heartbeat interval on parse failure, got %v", cfg.HeartbeatInterval)
	}
}

func TestNewConfigIndirectPingCount(t *testing.T) {
	origToken := os.Getenv("ORCH_CLUSTER_TOKEN")
	origCount := os.Getenv("ORCH_INDIRECT_PING_COUNT")
	defer func() {
		if origToken == "" {
			os.Unsetenv("ORCH_CLUSTER_TOKEN")
		} else {
			os.Setenv("ORCH_CLUSTER_TOKEN", origToken)
		}
		if origCount == "" {
			os.Unsetenv("ORCH_INDIRECT_PING_COUNT")
		} else {
			os.Setenv("ORCH_INDIRECT_PING_COUNT", origCount)
		}
	}()

	os.Setenv("ORCH_CLUSTER_TOKEN", "9876")
	os.Setenv("ORCH_INDIRECT_PING_COUNT", "5")

	cfg, err := NewConfig()
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.IndirectPingCount != 5 {
		t.Fatalf("expected indirect ping count 5, got %d", cfg.IndirectPingCount)
	}
}
