# dockroute

Local development proxy for Docker that eliminates port conflicts by routing via hostnames. Uses Traefik as a reverse proxy — web services are accessed at `http://<project>.localhost` instead of `localhost:<port>`.

## Codebase

- `bin/dockroute` — CLI entrypoint (Bash). Manages the Traefik container and Docker network.
- `share/docker-compose.yml` — Traefik service definition. Mounted read-only to the Docker socket.
- `VERSION` — Semver, read by CI for releases. Also hardcoded in `bin/dockroute` (keep in sync).

## Key constants

- Docker network: `dockroute` (external, created by `dockroute start`)
- Traefik container: `dockroute-traefik`
- Dashboard: `http://dockroute.localhost`
- Compose project name: `dockroute`
- Legacy network name: `proxy` (v1.x, migration handled in `bin/dockroute`)

## Development

- Shell scripts are checked by **shellcheck** and formatted by **shfmt** (pre-commit hook in `.githooks/pre-commit`)
- Indentation: tabs (enforced by shfmt)
- CI mirrors the pre-commit checks (`.github/workflows/test.yml`)
- `dockroute check [path]` — lints a compose file against dockroute conventions (missing labels, exposed ports, network issues). Run it after modifying any project's `docker-compose.yml`.

## Docker Compose conventions for projects using dockroute

When modifying `docker-compose.yml` files in any project that uses dockroute, follow these rules:

### Web services — replace `ports:` with Traefik labels

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<prefix>.rule=Host(`<prefix>.localhost`)"
  - "traefik.http.services.<prefix>.loadbalancer.server.port=<container-port>"
networks:
  - dockroute
  - default
```

- `traefik.enable=true` is required — Traefik ignores containers without it
- `<prefix>` must be project-scoped (e.g., `myapp`, not `app` or `web`)
- Use the project directory name (lowercased, hyphens allowed) as the prefix
- Remove the `ports:` mapping from the service

### HTTPS web services — opt-in after `dockroute tls setup`

To serve a web service over HTTPS, add `entrypoints=websecure` and `tls=true` to its HTTP router labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<prefix>.rule=Host(`<prefix>.localhost`)"
  - "traefik.http.routers.<prefix>.entrypoints=websecure"
  - "traefik.http.routers.<prefix>.tls=true"
  - "traefik.http.services.<prefix>.loadbalancer.server.port=<container-port>"
networks:
  - dockroute
  - default
```

- Requires `dockroute tls setup` (one-time) — generates `*.localhost` TLS certs
- HTTP-only services continue to work unchanged — HTTPS is opt-in per service
- For HTTP → HTTPS redirect, add a second router with `middlewares=redirect-https@file`

### PostgreSQL services — TCP labels for hostname routing

PostgreSQL services should use TCP labels for hostname routing instead of exposed ports. This requires a one-time `dockroute tls setup`.

```yaml
db:
  image: postgres:16
  labels:
    - "traefik.enable=true"
    - "traefik.tcp.routers.<prefix>-db.rule=HostSNI(`<prefix>-db.localhost`)"
    - "traefik.tcp.routers.<prefix>-db.entrypoints=postgres"
    - "traefik.tcp.routers.<prefix>-db.tls=true"
    - "traefik.tcp.services.<prefix>-db.loadbalancer.server.port=5432"
  networks:
    - dockroute
    - default
```

- Host connections require `sslmode=require`: `postgres://user:pass@<prefix>-db.localhost:5432/mydb?sslmode=require`
- Internal app connections are unchanged: `postgres://user:pass@db:5432/mydb` (no TLS needed)
- TCP router names must be project-scoped (e.g., `myapp-db`, not `db` or `postgres`)
- Do NOT use `HostSNI(*)` — it prevents multi-project routing

### Other internal services — remove `ports:`

Caches and message brokers (mysql, redis, memcached, rabbitmq, elasticsearch) should have no `ports:` mapping. Apps connect via Docker's internal network using the service name (e.g., `redis://redis:6379`).

If a port is exposed for host-side GUI tools (TablePlus, RedisInsight), use an environment variable: `"${REDIS_PORT:-6379}:6379"` with the port set in `.env`.

### Supporting services — flat subdomain pattern

Services like Mailhog, Mailpit, SonarQube, MinIO console, phpMyAdmin use the pattern `<prefix>-<service>.localhost` (e.g., `myapp-mail.localhost`, `myapp-minio.localhost`). Do NOT use nested subdomains like `mail.myapp.localhost` — they break wildcard SSL certificates.

### WebSocket services

Use `<prefix>-ws.localhost` as hostname (e.g., `myapp-ws.localhost`). Must be on the `dockroute` network.

### Network declaration

Every project using dockroute must declare the network as external:

```yaml
networks:
  dockroute:
    external: true
```

### Host routes — native apps running outside Docker

For apps running natively on the host (not in Docker), use `dockroute route` instead of Docker labels:

```bash
dockroute route add myapp.localhost 3000          # HTTP only
dockroute route add myapp.localhost 3000 --https  # HTTP + HTTPS (requires tls setup)
dockroute route add myapp-db.localhost 5432 --tcp # TCP/PostgreSQL (requires tls setup)
```

- Use `dockroute route` when: the app runs natively (e.g., `npm run dev` on the host)
- Use Docker labels when: the app runs in a Docker container
- `--tcp` routes use `HostSNI()` on the `postgres` entrypoint — connect with `sslmode=require`
- `--https` and `--tcp` are mutually exclusive
- Hostnames must be flat `<name>.localhost` — no nested subdomains
- `dockroute.localhost` is reserved for the dashboard
- If both a Docker container and a host route claim the same hostname, `route add` will fail

### x-dockroute compose extension

Declare host routes in `docker-compose.yml` so `dockroute check` can validate them:

```yaml
x-dockroute:
  routes:
    - "myapp.localhost 3000"
    - "myapp-api.localhost 3001 https"
    - "myapp-db.localhost 5432 tcp"
```

- Format: `<hostname> <port> [https|tcp]` — same as the routes file
- `dockroute check` validates format, checks registration, and detects collisions with Docker labels

### Label format

Always use double-quoted label strings with backtick-enclosed hostnames:

```yaml
- "traefik.http.routers.myapp.rule=Host(`myapp.localhost`)"
```
