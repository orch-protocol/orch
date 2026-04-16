#!/bin/bash

# Get the directory of the script
export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$DIR/../.." && pwd )"

# Kill all background processes on exit
trap 'JOBS=$(jobs -p); if [ -n "$JOBS" ]; then kill $JOBS 2>/dev/null; fi' EXIT

export ORCH_CLUSTER_TOKEN=12345
export ORCH_SEEDS=127.0.0.1:7945
export ORCH_SERVER_COUNT=${ORCH_SERVER_COUNT:-3}
export ORCH_DESIRED_COUNT=$ORCH_SERVER_COUNT
export ORCH_SCALE_SERVICE="http-server"
export ORCH_LOG_LEVEL=OFF

# Massive timeouts for ultra-stable local testing
export ORCH_HEARTBEAT_TIMEOUT=10000ms
export ORCH_SUSPECT_TIMEOUT=20000ms
export ORCH_ELECTION_TIMEOUT_MIN=1000ms
export ORCH_ELECTION_TIMEOUT_MAX=2000ms
export ORCH_SCALE_INTERVAL=30s

# Scale out command for seed node. PORT=0 means automatic port assignment
# Adding log redirection to identify start-up failures
export ORCH_SCALE_CMD="ORCH_PORT=0 PORT=0 $DIR/server_bin >> $DIR/scale_out.log 2>&1 &"

echo "Building binaries..."
go build -o "$DIR/lb_bin" "$PROJECT_ROOT/examples/loadbalancer/lb/main.go"
go build -o "$DIR/server_bin" "$PROJECT_ROOT/examples/loadbalancer/server/main.go"

echo "Starting Load Balancer (Orch: 7945, LB: 8000)..."
ORCH_PORT=7945 LB_PORT=8000 ORCH_SEEDS="" "$DIR/lb_bin" &
sleep 2

for i in $(seq 1 $ORCH_SERVER_COUNT); do
    O_PORT=$((7945 + 30*i))
    H_PORT=$((O_PORT + 1000))
    echo "Starting HTTP Server $i (Orch: $O_PORT, HTTP: $H_PORT)..."
    ORCH_SCALE_CMD="$DIR/server_bin" ORCH_PORT=$O_PORT PORT=$H_PORT "$DIR/server_bin" &
done

echo "------------------------------------------------"
echo "Cluster is starting with $ORCH_SERVER_COUNT backends."
echo "Use 'kill <pid>' to test node failure."
echo "------------------------------------------------"

wait
