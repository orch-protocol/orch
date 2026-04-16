package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	NodeID             string
	Addr               string
	BindAddr           string
	Seeds              []string
	ClusterToken       uint64
	Service            string
	Version            string
	HeartbeatInterval  time.Duration
	HeartbeatTimeout   time.Duration
	SuspectTimeout     time.Duration
	IndirectPingCount  int
	ElectionTimeoutMin time.Duration
	ElectionTimeoutMax time.Duration
	ScaleCommand       string
	ScaleInterval      time.Duration
	ScaleCPUThreshold  float32
	ScaleMemThreshold  float32
	ScaleDelta         uint32
	DesiredCount       uint32
	LogLevel           string
	ScaleService       string
}

func NewConfig() (*Config, error) {
	clusterToken, err := parseUint64Env("ORCH_CLUSTER_TOKEN")
	if err != nil {
		return nil, err
	}

	nodeID := os.Getenv("ORCH_NODE_ID")
	if nodeID == "" {
		nodeID = ""
	}

	addr := os.Getenv("ORCH_ADDR")
	if addr == "" {
		addr = "0.0.0.0:7946"
	}

	bindAddr := os.Getenv("ORCH_BIND_ADDR")
	if bindAddr == "" {
		bindAddr = addr
	}

	service := os.Getenv("ORCH_SERVICE")
	version := os.Getenv("ORCH_VERSION")
	if version == "" {
		version = "0.0.1"
	}

	seeds := strings.TrimSpace(os.Getenv("ORCH_SEEDS"))
	var seedList []string
	if seeds != "" {
		for _, s := range strings.Split(seeds, ",") {
			if trimmed := strings.TrimSpace(s); trimmed != "" {
				seedList = append(seedList, trimmed)
			}
		}
	}

	return &Config{
		NodeID:             nodeID,
		Addr:               addr,
		BindAddr:           bindAddr,
		Seeds:              seedList,
		ClusterToken:       clusterToken,
		Service:            service,
		Version:            version,
		HeartbeatInterval:  ParseDurationEnv("ORCH_HEARTBEAT_INTERVAL", 1000*time.Millisecond),
		HeartbeatTimeout:   ParseDurationEnv("ORCH_HEARTBEAT_TIMEOUT", 3000*time.Millisecond),
		SuspectTimeout:     ParseDurationEnv("ORCH_SUSPECT_TIMEOUT", 5000*time.Millisecond),
		IndirectPingCount:  ParseIntEnv("ORCH_INDIRECT_PING_COUNT", 3),
		ElectionTimeoutMin: ParseDurationEnv("ORCH_ELECTION_TIMEOUT_MIN", 150*time.Millisecond),
		ElectionTimeoutMax: ParseDurationEnv("ORCH_ELECTION_TIMEOUT_MAX", 300*time.Millisecond),
		ScaleCommand:       strings.TrimSpace(os.Getenv("ORCH_SCALE_CMD")),
		ScaleInterval:      ParseDurationEnv("ORCH_SCALE_INTERVAL", 60*time.Second),
		ScaleCPUThreshold:  float32(ParseFloatEnv("ORCH_SCALE_CPU_THRESHOLD", 0.8)),
		ScaleMemThreshold:  float32(ParseFloatEnv("ORCH_SCALE_MEM_THRESHOLD", 0.8)),
		ScaleDelta:         uint32(ParseIntEnv("ORCH_SCALE_DELTA", 1)),
		DesiredCount:       uint32(ParseIntEnv("ORCH_DESIRED_COUNT", 0)),
		LogLevel:           os.Getenv("ORCH_LOG_LEVEL"),
		ScaleService:       os.Getenv("ORCH_SCALE_SERVICE"),
	}, nil
}

func parseUint64Env(name string) (uint64, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return 0, fmt.Errorf("%s is required", name)
	}
	v, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", name, err)
	}
	return v, nil
}

func ParseDurationEnv(name string, defaultValue time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return defaultValue
	}
	d, err := time.ParseDuration(value)
	if err != nil {
		return defaultValue
	}
	return d
}

func ParseIntEnv(name string, defaultValue int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return defaultValue
	}
	i, err := strconv.Atoi(value)
	if err != nil {
		return defaultValue
	}
	return i
}

func ParseFloatEnv(name string, defaultValue float64) float64 {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return defaultValue
	}
	f, err := strconv.ParseFloat(value, 32)
	if err != nil {
		return defaultValue
	}
	return f
}
