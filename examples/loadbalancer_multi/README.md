# Orch Load Balancer Multi-Machine Example

This example demonstrates the Orch protocol running across multiple virtual machines (containers) using Docker Compose.

## How it works

1.  **Load Balancer (`lb`)**: Acts as a seed node and a reverse proxy. It monitors the Orch cluster for nodes offering the `http-server` service.
2.  **Backends (`server1`, `server2`, `server3`)**: Join the cluster by connecting to the `lb` seed. They advertise themselves as `http-server` instances.
3.  **Self-Healing**: If a backend container is stopped, Orch will detect the failure via gossip and the Load Balancer will automatically remove it from the rotation.

## Running the example

### 1. Start the cluster

```bash
docker compose up --build
```

### 2. Verify the Load Balancer

Open your browser or use `curl` to access the load balancer:

```bash
curl http://localhost:8000
```

You should see responses from different servers (round-robin):
- `Hello from <hostname-1> (Port: 8080)`
- `Hello from <hostname-2> (Port: 8080)`
- `Hello from <hostname-3> (Port: 8080)`

### 3. Test Failover

Stop one of the backend servers:

```bash
docker compose stop server1
```

Watch the logs of the `lb` container. Within a few seconds, it should log:
`CLUSTER STATUS: DEGRADED | Service 'http-server': 2/3 nodes alive`

Requests to `http://localhost:8000` will now only be routed to the remaining servers.

### 4. Test Recovery

Start the server again:

```bash
docker compose start server1
```

The load balancer will automatically detect the new node and add it back to the rotation.
`CLUSTER STATUS: HEALTHY | Service 'http-server': 3/3 nodes alive`

## Self-Healing (Automatic Recovery)

This example is configured to automatically recover from failures without manual intervention.

### How it works

1.  The `lb` (Leader) container has access to the host's Docker socket (`/var/run/docker.sock`).
2.  It monitors the number of alive `http-server` nodes.
3.  If the count falls below `ORCH_DESIRED_COUNT=3`, it executes `ORCH_SCALE_CMD` which is `docker start orch-server1 orch-server2 orch-server3`.

### Testing Self-Healing

1.  Stop a container:
    ```bash
    docker compose stop server1
    ```
2.  Watch the `lb` logs. You will see:
    - Cluster status enters `DEGRADED`.
    - Once the node is declared `DEAD` (after timeouts), the leader logs:
      `scale manager: service 'http-server' count (2) below desired (3), launching...`
    - The leader then starts the container again automatically.
    - Shortly after, the cluster returns to `HEALTHY`.

## Networking Details

Each container runs an Orch node configured with:
- `ORCH_ADDR`: The address other nodes use to reach this node (e.g., `server1:7946`).
- `ORCH_SEEDS`: The address of at least one other node in the cluster (e.g., `lb:7945`).

Docker Compose provides DNS resolution for service names, allowing nodes to find each other by name.
