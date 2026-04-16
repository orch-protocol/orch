package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/orch-protocol/orch"
)

func main() {
	portStr := getEnv("PORT", "8080")
	port, err := strconv.Atoi(portStr)
	if err != nil {
		log.Fatalf("invalid PORT: %v", err)
	}

	orchPortStr := getEnv("ORCH_PORT", "7946")
	// For Docker, we need to know our own address to advertise it to others.
	orchAddr := getEnv("ORCH_ADDR", "localhost:"+orchPortStr)

	clusterTokenStr := getEnv("ORCH_CLUSTER_TOKEN", "12345")
	clusterToken, err := strconv.ParseUint(clusterTokenStr, 10, 64)
	if err != nil {
		log.Fatalf("invalid ORCH_CLUSTER_TOKEN: %v", err)
	}

	seeds := getEnv("ORCH_SEEDS", "")
	var seedList []string
	if seeds != "" {
		seedList = []string{seeds}
	}

	// HTTP Server
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hostname, _ := os.Hostname()
		fmt.Fprintf(w, "Hello from %s (Port: %d)\n", hostname, port)
		log.Printf("Handled request from %s", r.RemoteAddr)
	})

	server := &http.Server{
		Addr:    ":" + portStr, // Bind to all interfaces for Docker
		Handler: mux,
	}

	// Start HTTP Server
	go func() {
		log.Printf("HTTP server starting on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server failed: %v", err)
			os.Exit(1)
		}
	}()

	// Small delay to ensure HTTP server is bound
	time.Sleep(1 * time.Second)

	// Initialize ORCH node
	cfg := &orch.Config{
		Addr:         orchAddr,
		BindAddr:     ":" + orchPortStr,
		Service:      "http-server",
		ClusterToken: clusterToken,
		Seeds:        seedList,
	}

	node, err := orch.NewNode(cfg)
	if err != nil {
		log.Fatalf("failed to create orch node: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := node.Start(ctx); err != nil {
		log.Fatalf("failed to start orch node: %v", err)
	}

	// Graceful shutdown
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	<-sigs

	log.Println("Shutting down...")
	cancel()
	server.Shutdown(context.Background())
	node.Shutdown()
}

func getEnv(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}
