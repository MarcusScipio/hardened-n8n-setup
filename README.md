# n8n Self-Hosted (Hardened)

A production-ready, security-first n8n deployment using Docker Compose. Every container is locked down: read-only filesystems, dropped capabilities, non-root users, isolated networks, and resource limits across the board.

This is not the "just run `docker-compose up` and pray" setup. This is the one you actually want in production.

![Stack Overview](https://img.shields.io/badge/containers-10-blue)
![TLS](https://img.shields.io/badge/TLS-Let's%20Encrypt-green)
![Monitoring](https://img.shields.io/badge/monitoring-Prometheus%20%2B%20Grafana-orange)

## What's in the box

| Service | Role |
|---------|------|
| **n8n** | Workflow engine, running in queue mode |
| **PostgreSQL 16** | Persistent database backend |
| **Redis 7** | Job queue for async execution |
| **Traefik v3** | Reverse proxy, automatic HTTPS, rate limiting |
| **pg-backup** | Automated daily database dumps with retention |
| **Prometheus** | Metrics collection (separate bootstrap) |
| **Grafana** | Dashboards and alerting (separate bootstrap) |
| **Postgres Exporter** | PostgreSQL metrics for Prometheus |
| **Redis Exporter** | Redis metrics for Prometheus |

## Architecture

```
                    Internet
                       │
                       ▼
              ┌─────────────────┐
              │    Traefik       │  :80 (redirect) + :443 (TLS)
              │    reverse proxy │
              └────────┬────────┘
                       │ n8n-frontend network
          ┌────────────┼────────────┐
          ▼                         ▼
   ┌──────────────┐        ┌──────────────┐
   │     n8n      │        │   Grafana    │
   │   :5678      │        │ /grafana     │
   └──────┬───────┘        └──────┬───────┘
          │ n8n-backend           │ n8n-monitoring
          │ (internal)            │ (internal)
   ┌──────┴───────┐        ┌─────┴────────┐
   │  PostgreSQL  │        │  Prometheus  │
   │  Redis       │        │  Exporters   │
   │  pg-backup   │        │              │
   └──────────────┘        └──────────────┘
```

Three isolated networks keep things separated:

- **n8n-backend** (internal, no internet access): Postgres, Redis, n8n, backup, exporters
- **n8n-frontend** (bridged): Traefik, n8n, Grafana. Only Traefik publishes ports.
- **n8n-monitoring** (internal, no internet access): Prometheus, Grafana, exporters, Traefik, n8n

## Prerequisites

- A Linux server (or VM) with Docker and Docker Compose v2 installed
- A domain name pointed at your server's IP (for Let's Encrypt TLS)
- Ports 80 and 443 open

## Quick Start

### 1. Clone and configure

```bash
git clone <your-repo-url> && cd self-hosted

# Copy the example env file and fill in your values
cp .env.example .env
```

Open `.env` and set these:

```env
POSTGRES_PASSWORD=your-strong-db-password
N8N_ENCRYPTION_KEY=...    # generate with: openssl rand -hex 32
N8N_JWT_SECRET=...        # generate with: openssl rand -hex 32
N8N_HOST=n8n.yourdomain.com
ACME_EMAIL=you@yourdomain.com
```

### 2. Start the app stack

```bash
docker compose up -d
```

This brings up n8n, Postgres, Redis, Traefik, and the backup service. It also creates the shared Docker networks that the monitoring stack will use.

Give it about 30 seconds for health checks to pass. You can watch the progress:

```bash
docker compose ps
docker compose logs -f n8n
```

Once healthy, visit `https://n8n.yourdomain.com` and create your admin account.

### 3. Start the monitoring stack (optional but recommended)

```bash
cd monitoring
cp .env.example .env
# Edit .env: set GF_SECURITY_ADMIN_PASSWORD and make sure
# POSTGRES_PASSWORD and N8N_HOST match the parent .env
docker compose up -d
```

Grafana will be available at `https://n8n.yourdomain.com/grafana/` with Prometheus pre-configured as a data source.

## Project Structure

```
self-hosted/
├── .env.example                              # App stack secrets template
├── .gitignore
├── docker-compose.yml                        # App stack (n8n + infra)
├── config/
│   ├── prometheus/
│   │   └── prometheus.yml                    # Scrape targets config
│   └── grafana/
│       └── provisioning/
│           └── datasources/
│               └── prometheus.yml            # Auto-provision data source
└── monitoring/
    ├── .env.example                          # Monitoring secrets template
    └── docker-compose.yml                    # Prometheus + Grafana + exporters
```

## Security Hardening

Every container in this stack follows the same hardening playbook:

**Filesystem**
- Read-only root filesystem (`read_only: true`)
- Writable paths limited to named volumes and explicit `tmpfs` mounts
- All `tmpfs` mounts use `noexec,nosuid` flags

**Process isolation**
- All Linux capabilities dropped (`cap_drop: ALL`), added back only when strictly needed
- `no-new-privileges` prevents privilege escalation after container start
- Non-root users with explicit UID:GID on every service

**Network isolation**
- Backend services (Postgres, Redis) have zero internet access via `internal: true` networks
- Only Traefik publishes ports to the host
- Services only join the networks they actually need

**Resource limits**
- CPU and memory limits on every container
- Prevents any single service from starving the host

**Traefik specifics**
- Docker socket mounted read-only
- Dashboard disabled
- `exposedbydefault=false` so new containers aren't auto-exposed
- HSTS preloading, XSS protection, frame denial, content-type sniffing prevention
- Rate limiting (100 req/min with burst tolerance of 50)

**Redis specifics**
- Dangerous commands (`FLUSHDB`, `FLUSHALL`, `DEBUG`) renamed to empty strings
- Protected mode enabled
- Memory capped with LRU eviction

**Postgres specifics**
- Image pinned by SHA256 digest, not just tag
- `PGDATA` on a dedicated volume, everything else immutable

## Backups

The `pg-backup` service runs automated `pg_dump` on a schedule:

| Setting | Default |
|---------|---------|
| Schedule | Daily |
| Keep daily backups | 7 days |
| Keep weekly backups | 4 weeks |
| Keep monthly backups | 6 months |

Backups are stored in the `pg_backups` Docker volume. To copy them to the host:

```bash
docker cp n8n-pg-backup:/backups ./backups
```

For off-site backup, mount a different volume driver or add a sync job to your cloud storage of choice.

### Manual backup

```bash
docker exec n8n-postgres pg_dump -U n8n -d n8n > backup_$(date +%Y%m%d).sql
```

### Restore

```bash
cat backup_20260317.sql | docker exec -i n8n-postgres psql -U n8n -d n8n
```

## Monitoring

The monitoring stack is intentionally separate from the app stack. It runs as its own Compose project and connects to the app's Docker networks as external. This means:

- You can restart or update monitoring without touching n8n
- You can tear it down entirely and n8n keeps running
- If you run multiple n8n instances later, one monitoring stack can observe them all

### What gets scraped

| Target | Endpoint | Port |
|--------|----------|------|
| n8n | `/metrics` | 5678 |
| Traefik | `/metrics` | 8082 (internal) |
| PostgreSQL | via postgres-exporter | 9187 |
| Redis | via redis-exporter | 9121 |

### Adding Grafana dashboards

Grafana starts with Prometheus pre-provisioned. Some recommended dashboard IDs to import:

- **n8n**: Check the [n8n docs](https://docs.n8n.io) for their official dashboard JSON
- **PostgreSQL**: `9628`
- **Redis**: `11835`
- **Traefik**: `17346`

Import via Grafana UI > Dashboards > Import > paste the ID.

## Updating

### n8n

```bash
docker compose pull n8n
docker compose up -d n8n
```

Consider pinning n8n to a specific version tag instead of `latest` for production stability:

```yaml
image: n8nio/n8n:1.82.1
```

### Monitoring stack

```bash
cd monitoring
docker compose pull
docker compose up -d
```

## Troubleshooting

**n8n won't start, logs show database connection errors**

Postgres might still be initializing. Check its health:
```bash
docker compose ps postgres
docker compose logs postgres
```

**Let's Encrypt certificate not issued**

Make sure port 80 is reachable from the internet. Traefik needs it for the HTTP-01 challenge. Check:
```bash
docker compose logs traefik | grep acme
```

**Grafana shows "No data" in dashboards**

The monitoring stack needs to reach the app containers through shared networks. Make sure you started the app stack first (it creates the networks).

**Redis exporter can't connect**

If you renamed Redis commands, the exporter's `PING` still works since we didn't rename it. Check the Redis logs:
```bash
docker compose logs redis
```

## License

MIT

---

Built with care, not with defaults.
