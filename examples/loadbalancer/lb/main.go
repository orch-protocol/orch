package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/orch-protocol/orch"
)

type LoadBalancer struct {
	node         orch.Node
	mu           sync.RWMutex
	targets      []*url.URL
	current      int
	desiredCount int
	serviceName  string
	startTime    time.Time
}

func NewLoadBalancer(node orch.Node, serviceName string, desiredCount int) *LoadBalancer {
	return &LoadBalancer{
		node:         node,
		serviceName:  serviceName,
		desiredCount: desiredCount,
		startTime:    time.Now(),
	}
}

func (lb *LoadBalancer) updateTargets() {
	lb.mu.Lock()
	defer lb.mu.Unlock()

	nodes := lb.node.AliveNodesInfo()
	var newTargets []*url.URL
	count := 0

	log.Printf("Cluster view: %d nodes alive", len(nodes))
	for _, n := range nodes {
		if n.Service == lb.serviceName {
			count++
			// Convention: HTTP port is orch port + 1000
			host, portStr, err := net.SplitHostPort(n.Addr)
			if err != nil {
				continue
			}
			port, _ := strconv.Atoi(portStr)
			httpPort := port + 1000

			u, _ := url.Parse(fmt.Sprintf("http://%s:%d", host, httpPort))
			newTargets = append(newTargets, u)
			log.Printf("  - Backend: %s (%s)", n.ID, u.String())
		}
	}

	// Halt condition: Don't kill LB, just log error. Self-healing should recover.
	if count == 0 && time.Since(lb.startTime) > 25*time.Second {
		log.Printf("ERROR: No healthy nodes for service '%s' found. Waiting for recovery...", lb.serviceName)
	}

	status := "HEALTHY"
	if count < lb.desiredCount {
		status = "DEGRADED"
	}
	if count == 0 {
		status = "FAILING"
	}

	log.Printf("CLUSTER STATUS: %s | Service '%s': %d/%d nodes alive | Total nodes: %d",
		status, lb.serviceName, count, lb.desiredCount, len(nodes))

	lb.targets = newTargets
}

func (lb *LoadBalancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	lb.mu.RLock()
	if len(lb.targets) == 0 {
		lb.mu.RUnlock()
		http.Error(w, "No healthy backends (cluster still converging?)", http.StatusServiceUnavailable)
		return
	}

	target := lb.targets[lb.current%len(lb.targets)]
	lb.current++
	lb.mu.RUnlock()

	log.Printf("Proxying request to: %s", target)
	proxy := httputil.NewSingleHostReverseProxy(target)

	// Better resilience: handle proxy errors and potentially retry or inform user
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("Proxy error to %s: %v", target, err)
		http.Error(w, "Backend unavailable, please try again", http.StatusBadGateway)
	}

	proxy.ServeHTTP(w, r)
}

func main() {
	orchPortStr := getEnv("ORCH_PORT", "7945")
	lbPortStr := getEnv("LB_PORT", "8000")

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

	// Initialize ORCH node
	cfg := &orch.Config{
		Addr:         "127.0.0.1:" + orchPortStr,
		Service:      "load-balancer",
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

	serverCount := 3
	if sc := os.Getenv("ORCH_SERVER_COUNT"); sc != "" {
		if c, err := strconv.Atoi(sc); err == nil {
			serverCount = c
		}
	}

	lb := NewLoadBalancer(node, "http-server", serverCount)

	// Periodically update targets
	go func() {
		for {
			lb.updateTargets()
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
	}()

	// LB Server
	server := &http.Server{
		Addr:    ":" + lbPortStr,
		Handler: lb,
	}

	go func() {
		log.Printf("Load Balancer starting on :%s", lbPortStr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("LB server failed: %v", err)
		}
	}()

	// Graceful shutdown
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	<-sigs

	log.Println("Shutting down...")
	cancel() // Cancel context first to stop gossip loops
	server.Shutdown(context.Background())
	node.Shutdown()
}

func getEnv(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}
