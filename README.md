# dockroute

Local development proxy for Docker — no more port conflicts.

Run multiple Docker projects simultaneously, each accessible via hostname:
- `http://myapp.localhost`
- `http://api.localhost`
- `http://dashboard.localhost`

## The Problem

Running multiple Docker projects locally causes port conflicts:
```
Error: Bind for 0.0.0.0:6379 failed: port is already allocated
```

This happens because each project's `docker-compose.yml` maps the same host ports:
```
Project A: localhost:3000, localhost:5432, localhost:6379
Project B: localhost:3000, localhost:5432, localhost:6379 → CONFLICT ❌
```

## The Solution

dockroute runs Traefik as a reverse proxy. Web services are routed by hostname instead of port, and databases/caches stay internal to Docker's network — no exposed ports, no conflicts:
```
Project A: myapp.localhost → Traefik → container_a:3000
Project B: api.localhost   → Traefik → container_b:3000
```

Databases and caches (Postgres, Redis, etc.) don't need `ports:` mappings at all — your app connects to them over Docker's internal network using the service name (e.g., `redis:6379`). No host port, no conflict.

Both projects run simultaneously with no conflicts.

## Installation

### Homebrew

```bash
brew tap designorant/tap
brew install dockroute
```

### Manual

```bash
git clone https://github.com/designorant/dockroute.git
cd dockroute
./bin/dockroute start
```

## Usage

### Start the proxy

```bash
dockroute start
```

### Check status

```bash
dockroute status
```

### View dashboard

Open http://dockroute.localhost to see all routed services.

### Stop the proxy

```bash
dockroute stop
```

## Project Setup

Update your project's `docker-compose.yml`:

1. **Web services**: Replace `ports:` with Traefik labels and add the `proxy` network
2. **Databases/caches**: Remove `ports:` entirely — your app already connects via Docker's internal network

```yaml
services:
  app:
    build: .
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.localhost`)"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
    networks:
      - proxy
      - default
    # Remove ports: - "3000:3000"

  db:
    image: postgres:16
    # Remove ports: - "5432:5432"
    # App connects as postgres://user:pass@db:5432/mydb

  redis:
    image: redis
    # Remove ports: - "6379:6379"
    # App connects as redis://redis:6379

networks:
  proxy:
    external: true
```

Then start your project:
```bash
docker compose up -d
```

Access at: http://myapp.localhost

## WebSocket Support

WebSockets work over port 80 using hostname routing:

```yaml
services:
  soketi:
    image: quay.io/soketi/soketi:1.6-16-debian
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp-ws.rule=Host(`ws.myapp.localhost`)"
      - "traefik.http.services.myapp-ws.loadbalancer.server.port=6001"
    networks:
      - proxy
```

Access at: `ws.myapp.localhost` (no port needed)

## Mise Integration

Add to your project's `mise.toml` for automatic proxy startup:

```toml
[tasks.dev]
description = "Start development environment"
run = """
#!/bin/bash
dockroute ensure
docker compose up
"""

[tasks.dev-d]
description = "Start development environment (detached)"
run = """
#!/bin/bash
dockroute ensure
docker compose up -d
"""

[tasks.down]
description = "Stop development environment"
run = "docker compose down"
```

Then use:
```bash
mise run dev    # Start with logs
mise run dev-d  # Start detached
mise run down   # Stop
```

## Port Strategy

Everything routes through port 80 using hostnames — no port conflicts, no ports to remember:

| Service | Before | After |
|---------|--------|-------|
| Web app | `localhost:3000` | `myapp.localhost` |
| WebSockets | `localhost:6001` | `ws.myapp.localhost` |
| Mailhog | `localhost:8025` | `mail.myapp.localhost` |
| Database | `localhost:5432` | Not exposed (internal) |
| Redis | `localhost:6379` | Not exposed (internal) |

Databases and caches don't need exposed ports — your app connects via Docker's internal network using the service name (e.g., `postgres://user:pass@db:5432/mydb`).

If you need to connect to a database from the host (e.g., using TablePlus or RedisInsight), you can use `docker exec` or expose a unique port per project to avoid conflicts:

```yaml
# Project A                    # Project B
redis:                         redis:
  ports:                         ports:
    - "16379:6379"                 - "26379:6379"
```

The dashboard is available at `dockroute.localhost`.

## Extending with Custom Entrypoints

For TCP services (databases, Redis) that you want to expose, create a local override:

```yaml
# docker-compose.override.yml (in dockroute directory)
services:
  traefik:
    command:
      # Include all existing commands, plus:
      - "--entrypoints.postgres.address=:5432"
      - "--entrypoints.redis.address=:6379"
    ports:
      - "5432:5432"
      - "6379:6379"
```

Then configure TCP routing in your project:

```yaml
services:
  db:
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.myapp-db.rule=HostSNI(`*`)"
      - "traefik.tcp.routers.myapp-db.entrypoints=postgres"
      - "traefik.tcp.services.myapp-db.loadbalancer.server.port=5432"
```

**Note:** TCP routing by hostname requires TLS (SNI). For local dev, it's usually simpler to keep databases internal.

## How It Works

1. **Shared network**: All projects connect to a `proxy` network
2. **Single proxy**: Traefik listens on port 80 (dashboard at `dockroute.localhost`)
3. **Label-based routing**: Traefik reads container labels to configure routes
4. **Hostname resolution**: `.localhost` domains resolve to 127.0.0.1 automatically

## Commands

| Command | Description |
|---------|-------------|
| `dockroute start` | Start the proxy |
| `dockroute stop` | Stop the proxy |
| `dockroute status` | Show status and routed services |
| `dockroute logs` | Follow proxy logs |
| `dockroute ensure` | Start if not running (for scripts) |
| `dockroute version` | Show version |
| `dockroute help` | Show help |

## License

MIT
