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
| Redis | `localhost:6379` | Not exposed (internal) | — |

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

## PostgreSQL Routing

For PostgreSQL, dockroute supports hostname-based routing — multiple projects share port 5432, each accessible via its own hostname:

```
psql "host=myapp-db.localhost sslmode=require"       → Project A's Postgres
psql "host=storefront-db.localhost sslmode=require"   → Project B's Postgres
```

This works via PostgreSQL's STARTTLS protocol: clients initiate TLS with an SNI hostname, and Traefik routes to the correct backend. Requires `sslmode=require` in all connections.

### Setup

One-time setup (requires [mkcert](https://github.com/FiloSottile/mkcert)):

```bash
dockroute tls setup     # Generates *.localhost TLS certs
dockroute stop && dockroute start
```

### Project Configuration

Add TCP labels to your PostgreSQL service:

```yaml
services:
  db:
    image: postgres:16
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.myapp-db.rule=HostSNI(`myapp-db.localhost`)"
      - "traefik.tcp.routers.myapp-db.entrypoints=postgres"
      - "traefik.tcp.routers.myapp-db.tls=true"
      - "traefik.tcp.services.myapp-db.loadbalancer.server.port=5432"
    networks:
      - dockroute
      - default
```

No `ports:` mapping needed — Traefik handles it.

### Connecting

```bash
# psql
psql "host=myapp-db.localhost port=5432 sslmode=require user=postgres"

# Drizzle Kit / ORMs
DATABASE_URL=postgres://user:pass@myapp-db.localhost:5432/mydb?sslmode=require

# Internal app connections (unchanged, no TLS needed)
DATABASE_URL=postgres://user:pass@db:5432/mydb
```

**Important:** `sslmode=require` is mandatory for host connections. Without it, clients skip TLS and the connection fails.

### Limitations

- **PostgreSQL only** — MySQL's server-first protocol prevents SNI extraction; Redis has no STARTTLS support in Traefik
- **Port 5432 conflict** — if a local PostgreSQL server is running, stop it first or change its port
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

## Commands

| Command | Description |
|---------|-------------|
| `dockroute start` | Start the proxy |
| `dockroute stop` | Stop the proxy |
| `dockroute status` | Show status and routed services |
| `dockroute check [path]` | Check a compose file for dockroute issues |
| `dockroute logs` | Follow proxy logs |
| `dockroute ensure` | Start if not running (for scripts) |
| `dockroute tls setup` | Generate TLS certs for HTTPS and PostgreSQL routing |
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
- **Internal services** (Redis, MySQL, caches): Remove `ports:` — apps connect via Docker's internal network (e.g., `redis://redis:6379`). For host GUI access, use env var pattern: `"${REDIS_PORT:-6379}:6379"`.
- **Supporting services** (Mailhog, MinIO, etc.): Route through Traefik with flat subdomain: `<prefix>-<service>.localhost` (NOT `<service>.<prefix>.localhost`).
- **WebSocket services**: Use `<prefix>-ws.localhost` as hostname.
- **Naming**: Router names and hostnames must be project-scoped (`myapp`, not `app`).
- **Network**: Declare `dockroute` as external.
- **Label format**: `"traefik.http.routers.<prefix>.rule=Host(`<prefix>.localhost`)"` (double-quoted, backtick hostnames).
````

## License

[MIT](LICENSE) © [Michał Ordon](https://github.com/designorant)
