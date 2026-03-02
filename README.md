# dockroute

Local development proxy for Docker — no more port conflicts.

Run multiple Docker projects simultaneously, each accessible via hostname:
- `http://myapp.localhost`
- `http://myapp-api.localhost`
- `http://myapp-admin.localhost`

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
Project A: myapp.localhost      → Traefik → container_a:3000
Project B: storefront.localhost → Traefik → container_b:3000
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

1. **Web services**: Replace `ports:` with Traefik labels and add the `dockroute` network
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
      - dockroute
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
  dockroute:
    external: true
```

Then start your project:
```bash
docker compose up -d
```

Access at: http://myapp.localhost

## Checking Your Configuration

Run `dockroute check` in your project directory to verify your `docker-compose.yml` follows dockroute conventions:

```bash
cd ~/projects/myapp
dockroute check
```

It checks for common issues — missing Traefik labels, exposed database ports, missing network declarations, generic router names, and nested subdomains — and prints a ready-to-paste suggestion block with the fixes.

Exits with code 0 when all checks pass, 1 when issues are found. You can pass an explicit path: `dockroute check path/to/docker-compose.yml`.

## Running Multiple Projects

Each Docker Compose project has its own `default` network. Services like `db` and `redis` that stay on this network are automatically isolated — `redis://redis:6379` in Project A connects to Project A's Redis, not Project B's, even with identical service names. No changes needed.

Services exposed through Traefik join the shared `dockroute` network where both router names and hostnames must be globally unique. Prefix them with your project name:

```yaml
# Ambiguous — will collide with other projects using the same names
labels:
  - "traefik.http.routers.app.rule=Host(`app.localhost`)"
  - "traefik.http.services.app.loadbalancer.server.port=3000"

# Project-scoped — no conflicts
labels:
  - "traefik.http.routers.myapp.rule=Host(`myapp.localhost`)"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

This also applies to supporting services like Mailhog or SonarQube — use `myapp-mail.localhost` instead of `mail.localhost`, and `myapp-sonarqube.localhost` instead of `sonarqube.localhost`.

## WebSocket Support

WebSockets work over port 80 using hostname routing:

```yaml
services:
  soketi:
    image: quay.io/soketi/soketi:1.6-16-debian
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp-ws.rule=Host(`myapp-ws.localhost`)"
      - "traefik.http.services.myapp-ws.loadbalancer.server.port=6001"
    networks:
      - dockroute
```

Access at: `myapp-ws.localhost` (no port needed)

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

Everything routes through port 80 (or 443 with TLS) using hostnames — no port conflicts, no ports to remember:

| Service | Before | After | HTTPS |
|---------|--------|-------|-------|
| Web app | `localhost:3000` | `http://myapp.localhost` | `https://myapp.localhost` |
| WebSockets | `localhost:6001` | `http://myapp-ws.localhost` | `https://myapp-ws.localhost` |
| Mailhog | `localhost:8025` | `http://myapp-mail.localhost` | `https://myapp-mail.localhost` |
| PostgreSQL | `localhost:5432` | `myapp-db.localhost:5432` (TLS) | — |
| Redis | `localhost:6379` | `myapp-redis.localhost:6379` (TLS) | — |

Databases and caches don't need exposed ports — your app connects via Docker's internal network using the service name (e.g., `postgres://user:pass@db:5432/mydb`).

For tools like Redis CLI or `mysql`, the simplest option is `docker compose exec`:

```bash
docker compose exec redis redis-cli
```

For GUI tools (Redis, MySQL) that require a host port, use an environment variable so each project can set its own port in `.env`:

```yaml
# docker-compose.yml
services:
  redis:
    image: redis
    ports:
      - "${REDIS_PORT:-6379}:6379"
```

```bash
# .env (gitignored, set once per project)
REDIS_PORT=6380
```

The dashboard is available at `dockroute.localhost`.

## Host Routing

Developers often run infrastructure (Postgres, Redis) in Docker but run application code natively for faster iteration. dockroute can route hostnames to native processes running on your machine — no Docker container needed:

```bash
# Route myapp.localhost to your local dev server on port 3000
dockroute route add myapp.localhost 3000

# Start your native app
cd ~/projects/myapp && npm run dev  # listens on port 3000

# Access at http://myapp.localhost
curl http://myapp.localhost
```

This creates a Traefik file-provider route pointing at `host.docker.internal:<port>`, so it works alongside Docker-routed services. Use `dockroute route` for native apps and Docker labels for containerized apps.

### Commands

```bash
dockroute route add myapp.localhost 3000          # Add a route
dockroute route add myapp.localhost 3000 --https  # Add with HTTPS (requires tls setup)
dockroute route add myapp-db.localhost 5432 --tcp # Add TCP route (requires tls setup)
dockroute route list                              # List all host routes
dockroute route remove myapp.localhost            # Remove a route
```

### TCP Host Routes

Route TCP traffic (e.g., PostgreSQL) to a native process on your machine — no Docker container needed:

```bash
# Route to a local Postgres server
dockroute route add myapp-db.localhost 5432 --tcp

# Connect via hostname
psql "host=myapp-db.localhost sslmode=require"
```

TCP routes use Traefik's `HostSNI()` routing over dedicated entrypoints — `postgres` (port 5432) and `redis` (port 6379). The route port is the target port on your machine — often the same as the entrypoint port, but can differ if your local service listens elsewhere.

### Rules

- Hostnames must be flat `<name>.localhost` — nested subdomains (e.g., `mail.myapp.localhost`) are not supported
- `dockroute.localhost` is reserved for the dashboard
- `--https` requires `dockroute tls setup` and creates dual-stack routing (HTTP + HTTPS)
- `--tcp` requires `dockroute tls setup` and routes via `HostSNI()` on the postgres entrypoint (port 5432)
- `--https` and `--tcp` are mutually exclusive
- If a Docker container already claims the same hostname, `route add` will fail — remove the container's labels or choose a different hostname
- Running `dockroute route add` with the same hostname replaces the existing entry (port, flags)

### Declaring Host Routes in Compose Files

You can declare host routes in your `docker-compose.yml` using the `x-dockroute` extension. This lets `dockroute check` validate that the routes are registered:

```yaml
x-dockroute:
  routes:
    - "myapp.localhost 3000"
    - "myapp-api.localhost 3001 https"
    - "myapp-db.localhost 5432 tcp"
```

`dockroute check` will verify each entry's format (hostname, port, flags) and warn if a route isn't registered yet. It also detects conflicts between x-dockroute hostnames and Docker container labels in the same file.

## HTTPS Routing

After running `dockroute tls setup`, web services can use HTTPS via the `websecure` entrypoint. This is opt-in — HTTP-only services continue to work as before.

### Project Configuration

Add `entrypoints=websecure` and `tls=true` to your service labels:

```yaml
services:
  app:
    build: .
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.localhost`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
    networks:
      - dockroute
      - default

networks:
  dockroute:
    external: true
```

Access at: https://myapp.localhost

### HTTP → HTTPS Redirect (Optional)

To redirect HTTP requests to HTTPS for a specific service, add the `redirect-https@file` middleware (provided by `dockroute tls setup`):

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myapp.rule=Host(`myapp.localhost`)"
  - "traefik.http.routers.myapp.entrypoints=websecure"
  - "traefik.http.routers.myapp.tls=true"
  - "traefik.http.routers.myapp-http.rule=Host(`myapp.localhost`)"
  - "traefik.http.routers.myapp-http.entrypoints=web"
  - "traefik.http.routers.myapp-http.middlewares=redirect-https@file"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

This creates two routers: `myapp` handles HTTPS, and `myapp-http` catches HTTP requests and redirects them. No global redirect is applied — other services remain HTTP-only.

## TCP Routing (PostgreSQL & Redis)

dockroute supports hostname-based TCP routing — multiple projects share the same port, each accessible via its own hostname:

```
psql "host=myapp-db.localhost sslmode=require"       → Project A's Postgres
psql "host=storefront-db.localhost sslmode=require"   → Project B's Postgres
redis-cli --tls -h myapp-redis.localhost              → Project A's Redis
```

**PostgreSQL** uses STARTTLS — clients send a plain `SSLRequest` packet first, then upgrade to TLS. Traefik handles this natively: it recognizes the PostgreSQL negotiation, responds to it, then extracts the SNI hostname from the subsequent TLS handshake to route to the correct backend. This is why `sslmode=require` is mandatory — without it, the TLS handshake never happens and there's no hostname to route on.

**Redis** uses a dedicated TLS entrypoint on port 6379 where TLS starts immediately (no STARTTLS). Clients connect using the `rediss://` scheme, and Traefik extracts the SNI hostname from the TLS handshake to route to the correct backend.

### Setup

One-time setup (requires [mkcert](https://github.com/FiloSottile/mkcert)):

```bash
dockroute tls setup     # Generates *.localhost TLS certs
dockroute stop && dockroute start
```

### Project Configuration

Add TCP labels to your PostgreSQL and/or Redis services:

```yaml
services:
  db:
    image: postgres:16
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=dockroute"
      - "traefik.tcp.routers.myapp-db.rule=HostSNI(`myapp-db.localhost`)"
      - "traefik.tcp.routers.myapp-db.entrypoints=postgres"
      - "traefik.tcp.routers.myapp-db.tls=true"
      - "traefik.tcp.services.myapp-db.loadbalancer.server.port=5432"
    networks:
      - dockroute
      - default

  redis:
    image: redis:alpine
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=dockroute"
      - "traefik.tcp.routers.myapp-redis.rule=HostSNI(`myapp-redis.localhost`)"
      - "traefik.tcp.routers.myapp-redis.entrypoints=redis"
      - "traefik.tcp.routers.myapp-redis.tls=true"
      - "traefik.tcp.services.myapp-redis.loadbalancer.server.port=6379"
    networks:
      - dockroute
      - default
```

No `ports:` mapping needed — Traefik handles it.

**Important:** Services on multiple networks (both `dockroute` and `default`) must set `traefik.docker.network=dockroute`. Without it, Traefik may resolve the wrong network IP.

### Connecting

```bash
# PostgreSQL — psql
psql "host=myapp-db.localhost port=5432 sslmode=require user=postgres"

# PostgreSQL — ORMs
DATABASE_URL=postgres://user:pass@myapp-db.localhost:5432/mydb?sslmode=require

# Redis — redis-cli
redis-cli --tls -h myapp-redis.localhost -p 6379

# Redis — app connection string
REDIS_URL=rediss://myapp-redis.localhost:6379

# Internal app connections (unchanged, no TLS needed)
DATABASE_URL=postgres://user:pass@db:5432/mydb
REDIS_URL=redis://redis:6379
```

**Important:** TLS is mandatory for host connections — `sslmode=require` for PostgreSQL, `rediss://` for Redis. Without it, the TLS handshake never happens and there's no hostname to route on.

**Node.js TLS trust:** If using mkcert certificates, set `NODE_EXTRA_CA_CERTS="$(mkcert -CAROOT)/rootCA.pem"` so Node.js trusts the local CA. For Redis via `ioredis`, you may also need to set `tls.servername` to the dockroute hostname for SNI matching.

### Limitations

- **PostgreSQL and Redis only** — MySQL's server-first protocol prevents SNI extraction
- **Port conflicts** — if a local PostgreSQL server (5432) or Redis server (6379) is running, stop it first or change its port
- **Cert expiry** — mkcert certs last ~27 months; check with `dockroute tls status`

## Gotchas

### Framework dev servers still print `localhost:PORT`

After switching to dockroute, your framework's dev server will still log its internal listen address:

```
▲ Next.js 16.1.1
- Local: http://localhost:3000
```

This is the address **inside the container**, not how you access the app. Use the dockroute hostname (`myapp.localhost`) instead. There's nothing to fix — every framework does this.

### Content Security Policy needs updating

If your app sets a Content Security Policy, hardcoded `localhost:PORT` values will break. CSP directives like `connect-src` and `script-src` must match the dockroute hostnames:

```diff
- connect-src 'self' ws://localhost:6001
+ connect-src 'self' ws://myapp-ws.localhost:80
```

For Next.js, read the host/port from environment variables instead of hardcoding:

```typescript
// next.config.ts — build CSP from env vars
const soketiHost = process.env.NEXT_PUBLIC_SOKETI_HOST; // myapp-ws.localhost
const soketiPort = process.env.NEXT_PUBLIC_SOKETI_PORT; // 80
const connectSrc = soketiHost ? `ws://${soketiHost}:${soketiPort}` : '';
```

### `.env` files need updating

`docker-compose.yml` defaults (via `${VAR:-default}`) only apply when the variable is **unset**. If your `.env` file still has `localhost:3000` values, they override the dockroute defaults. Update your `.env` to match:

```env
NEXT_PUBLIC_APP_URL=http://myapp.localhost
NEXT_PUBLIC_SOKETI_HOST=myapp-ws.localhost
NEXT_PUBLIC_SOKETI_PORT=80
```

### Lazy-init proxies and the `in` operator

Some frameworks use lazy-initialized module proxies to defer heavy setup (database connections, etc.) until first use. If a library checks `"property" in proxy` to branch its behavior, the `in` operator uses the proxy's `has` trap — not `get`. A proxy with only a `get` trap will check the raw target object instead, potentially taking the wrong code path. Add a `has` trap if your proxy wraps a lazily-created object:

```typescript
export const instance = new Proxy({} as MyType, {
  get(_, prop) { return Reflect.get(getRealInstance(), prop); },
  has(_, prop) { return Reflect.has(getRealInstance(), prop); }, // ← don't forget this
});
```

## How It Works

1. **Shared network**: All projects connect to a `dockroute` network
2. **Single proxy**: Traefik listens on port 80 (dashboard at `dockroute.localhost`)
3. **Label-based routing**: Traefik reads container labels to configure routes
4. **Hostname resolution**: `.localhost` domains resolve to 127.0.0.1 automatically
5. **Project isolation**: Each project's `default` network keeps internal services separated; only Traefik-labeled services share the `dockroute` network
6. **File provider**: Host routes (from `dockroute route`) are written as Traefik file-provider configs, hot-reloaded without proxy restart

## Commands

| Command | Description |
|---------|-------------|
| `dockroute start` | Start the proxy |
| `dockroute stop` | Stop the proxy |
| `dockroute status` | Show status and routed services |
| `dockroute check [path]` | Check a compose file for dockroute issues |
| `dockroute logs` | Follow proxy logs |
| `dockroute ensure` | Start if not running (for scripts) |
| `dockroute route add <host> <port> [--https\|--tcp]` | Route hostname to a local port |
| `dockroute route list` | List host routes |
| `dockroute route remove <host>` | Remove a host route |
| `dockroute tls setup` | Generate TLS certs for HTTPS, PostgreSQL, and Redis routing |
| `dockroute tls status` | Show TLS certificate status |
| `dockroute tls remove` | Remove TLS certs and config |
| `dockroute version` | Show version |
| `dockroute help` | Show help |

## For AI Coding Agents

If you use AI coding agents (Claude Code, Cursor, Copilot, Codex, etc.), add the following to your project's `AGENTS.md` file so agents automatically follow dockroute conventions when working with your `docker-compose.yml`:

````markdown
## Docker (dockroute)

This project uses [dockroute](https://github.com/designorant/dockroute) for local Docker networking. Services are accessible at `http://<prefix>.localhost`.

### Rules for `docker-compose.yml`

- **Web services**: Replace `ports:` with Traefik labels (`traefik.enable=true`, router rule, loadbalancer port). Add both `dockroute` and `default` networks. Use the project directory name as the `<prefix>`.
- **PostgreSQL**: Use TCP labels for hostname routing (`traefik.tcp.routers.<prefix>-db.rule=HostSNI(...)`, `entrypoints=postgres`, `tls=true`). Requires `dockroute tls setup`. Connect with `sslmode=require` from host.
- **Redis**: Use TCP labels for hostname routing (`traefik.tcp.routers.<prefix>-redis.rule=HostSNI(...)`, `entrypoints=redis`, `tls=true`). Requires `dockroute tls setup`. Connect with `rediss://` from host.
- **Internal services** (MySQL, caches): Remove `ports:` — apps connect via Docker's internal network. For host GUI access, use env var pattern: `"${MYSQL_PORT:-3306}:3306"`.
- **Supporting services** (Mailhog, MinIO, etc.): Route through Traefik with flat subdomain: `<prefix>-<service>.localhost` (NOT `<service>.<prefix>.localhost`).
- **WebSocket services**: Use `<prefix>-ws.localhost` as hostname.
- **Naming**: Router names and hostnames must be project-scoped (`myapp`, not `app`).
- **Network**: Declare `dockroute` as external.
- **Label format**: `"traefik.http.routers.<prefix>.rule=Host(`<prefix>.localhost`)"` (double-quoted, backtick hostnames).
````

## License

[MIT](LICENSE) © [Michał Ordon](https://github.com/designorant)
