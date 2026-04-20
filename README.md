# Distributed Exchange System (Java + Erlang/OTP)

Active-Active 2-node exchange deployment with:
- **Container 1:** `10.2.1.3` (`nodeA@10.2.1.3`)
- **Container 2:** `10.2.1.14` (`nodeB@10.2.1.14`)

## Required Versions (Enforced)

- **Java:** `25.0.1-open`
- **Maven:** `3.9.11`
- **Erlang/OTP:** `28`

`pom.xml` now enforces Java and Maven versions at build time.  
The project uses the vendored `com.ericsson.otp.erlang` JInterface code aligned with OTP-era 2025 source, matching the Erlang 28 target runtime.

## Runtime Defaults (No localhost)

- Erlang cluster nodes default to:
  - `nodeA@10.2.1.3`
  - `nodeB@10.2.1.14`
- Java gateway defaults to:
  - `TRADER_BACKEND_NODES=nodeA@10.2.1.3,nodeB@10.2.1.14`
- Web dashboard defaults to round-robin websocket endpoints:
  - `ws://10.2.1.3:8085`
  - `ws://10.2.1.14:8085`

All defaults can be overridden via environment variables or command-line arguments.

## Build Locally

```bash
erlc -o ebin ./*.erl
mvn -DskipTests clean package
```

## Start Nodes Manually

```bash
./start_node_a.sh
./start_node_b.sh
```

## Active-Active Deployment Automation

Use the deployment script from your local machine:

```bash
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` performs:
1. Source sync to both containers (`rsync` or `scp` fallback).
2. Shared `.erlang.cookie` install on both nodes.
3. Remote Erlang + Java builds on each container.
4. Optional clean reset of runtime state (`CLEAN_START=1` wipes logs/run/Mnesia).
5. Erlang + Java process startup via SSH.
6. Cluster ping and process verification (only when both nodes are targeted).

For a clean start, run:
```bash
./deploy.sh
```

To restart just one node without wiping Mnesia (e.g. bring nodeA back):
```bash
TARGET_NODE=nodeA CLEAN_START=0 ./deploy.sh
```

## Environment Variables

- `NODE_A_IP` (default `10.2.1.3`)
- `NODE_B_IP` (default `10.2.1.14`)
- `ERLANG_COOKIE` (default `exchange_cookie`)
- `STOCK_CLUSTER_NODES` (default `nodeA@10.2.1.3,nodeB@10.2.1.14`)
- `TRADER_BACKEND_NODES` (default `nodeA@10.2.1.3,nodeB@10.2.1.14`)
- `TRADER_WS_PORT` (default `8085`)
- `TRADER_WS_HOST` (default `0.0.0.0`, overridden by `deploy.sh` to the node IP)
- `TRADER_LOCAL_NODE_HOST` (recommended in containers; set by `deploy.sh` so Java node names use the local container IP)
- `COOKIE_FILE` (default `.erlang.cookie`, read by `deploy.sh`)
- `CLEAN_START` (default `1`, set `0` to preserve in-memory Mnesia)
- `TARGET_NODE` (set `nodeA` or `nodeB` to operate on a single node)

