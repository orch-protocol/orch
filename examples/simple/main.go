// Simple ORCH server example
//
// This example demonstrates how to create a basic ORCH node that:
// - Joins a cluster (or bootstraps a new one)
// - Participates in gossip protocol
// - Handles graceful shutdown
//
// Usage:
//
//	# Bootstrap a new cluster
//	go run ./examples/simple
//
//	# Join an existing cluster
//	export ORCH_SEEDS=127.0.0.1:7946
//	go run ./examples/simple
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/orch-protocol/orch"
)

func main() {
	// Load configuration from environment variables
	cfg := loadConfig()

	// Create a new ORCH node
	node, err := orch.NewNode(cfg)
	if err != nil {
		log.Fatalf("failed to create node: %v", err)
	}

	// Start the node
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := node.Start(ctx); err != nil {
		log.Fatalf("failed to start node: %v", err)
	}

	log.Printf("Node started successfully")
	log.Printf("Cluster size: %d nodes", node.ClusterSize())
	log.Printf("This node is leader: %v", node.IsLeader())

	// Wait for interrupt signal
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	<-sigs

	log.Println("shutdown requested...")
	node.Shutdown()
	log.Println("node shut down successfully")
}

func loadConfig() *orch.Config {
	addr := getEnv("ORCH_ADDR", "0.0.0.0:7946")
	bindAddr := getEnv("ORCH_BIND_ADDR", addr)
	
	cfg := &orch.Config{
		NodeID:             getEnv("ORCH_NODE_ID", ""),
		Addr:               addr,     // Advertised address
		BindAddr:           bindAddr, // Actual listen address
		Service:            getEnv("ORCH_SERVICE", "simple-server"),
		Version:            getEnv("ORCH_VERSION", "1.0.0"),
		ClusterToken:       mustParseUint64Env("ORCH_CLUSTER_TOKEN"),
		Seeds:              parseSeeds(getEnv("ORCH_SEEDS", "")),
	}

	log.Printf("Config: Addr=%s, BindAddr=%s, Service=%s, ClusterToken=%d, Seeds=%v", 
		cfg.Addr, cfg.BindAddr, cfg.Service, cfg.ClusterToken, cfg.Seeds)
	
	return cfg
}

func getEnv(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

func mustParseUint64Env(key string) uint64 {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("%s is required", key)
	}
	// Simple parsing - in production, use proper error handling
	var result uint64
	for _, c := range v {
		if c < '0' || c > '9' {
			log.Fatalf("invalid %s: %s", key, v)
		}
		result = result*10 + uint64(c-'0')
	}
	return result
}

func parseSeeds(seeds string) []string {
	if seeds == "" {
		return nil
	}
	return split(seeds, ",")
}

func split(s, sep string) []string {
	var result []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == sep[0] {
			if i > start {
				result = append(result, s[start:i])
			}
			start = i + 1
		}
	}
	if start < len(s) {
		result = append(result, s[start:])
	}
	return result
}
