# n8n Self-Hosted (Hardened)

A production-ready, security-first n8n deployment using Docker Compose. Every container is locked down: read-only filesystems, dropped capabilities, non-root users, isolated networks, resource limits. No shortcuts.

Deploys the same way on-prem or cloud. Same security posture either way.

![Containers](https://img.shields.io/badge/containers-11-blue)
![TLS](https://img.shields.io/badge/TLS-always%20on-green)
![Monitoring](https://img.shields.io/badge/monitoring-Prometheus%20%2B%20Grafana-orange)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)

## What's in the box

| Service | What it does |
|---------|--------------|
| **n8n** | Workflow engine, queue mode with Redis |
| **PostgreSQL 16** | Database backend |
| **Redis 7** | Job queue for async workflow execution |
| **Traefik v3** | Reverse proxy, TLS, rate limiting, security headers |
| **Docker Socket Proxy** | Isolates the Docker socket from Traefik |
| **pg-backup** | Daily automated database dumps with retention |
| **Prometheus** | Metrics collection (separate stack) |
| **Grafana** | Dashboards and alerting (separate stack) |
| **Postgres Exporter** | DB metrics for Prometheus |
| **Redis Exporter** | Cache metrics for Prometheus |

## Architecture

```
                  Network / Internet
                       |
                       v
              +-------------------+
              |     Traefik       |  :80 (redirect) + :443 (TLS)
              |   reverse proxy   |
              +---------+---------+
                        | n8n-frontend
           +------------+------------+
           v                         v
    +--------------+        +--------------+
    |     n8n      |        |   Grafana    |
    |   :5678      |        |  /grafana    |
    +------+-------+        +------+-------+
           | n8n-backend           | n8n-monitoring
           | (internal)            | (internal)
    +------+-------+        +-----+--------+
    |  PostgreSQL  |        |  Prometheus  |
    |  Redis       |        |  Exporters   |
    |  pg-backup   |        |              |
    +--------------+        +--------------+
```

**Four isolated networks:**

- **n8n-socket** (internal) -- Socket proxy talks to Traefik. Nothing else.
- **n8n-backend** (internal, no internet) -- Postgres, Redis, n8n, backup, exporters.
- **n8n-frontend** (bridged) -- Traefik, n8n, Grafana. Only Traefik publishes ports.
- **n8n-monitoring** (internal, no internet) -- Prometheus, Grafana, exporters.

## TLS

TLS is always on. The setup script asks how you want to handle certificates:

| Mode | When to use | How it works |
|------|-------------|--------------|
| **Domain** | You have a domain pointed at the server | Traefik gets a Let's Encrypt cert automatically |
| **IP / localhost** | On-prem, LAN, no domain | Traefik uses its built-in self-signed cert |

Both use the same encryption strength. The difference is trust: Let's Encrypt certs are signed by a public CA so browsers trust them silently. Self-signed certs trigger a browser warning you click through once. On a LAN or known IP, that's fine.

## Prerequisites

- **Linux** server or VM (Ubuntu 22.04+, Debian 12+, or similar)
- Docker Engine and Docker Compose v2 installed
- Ports 80 and 443 available
- A domain pointed at the server (only if you want Let's Encrypt)

> **Why Linux and not macOS?** See [Platform Notes](#platform-notes) below.

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/MarcusScipio/hardened-n8n-setup.git
cd hardened-n8n-setup
```

Run the setup script. It walks you through TLS mode, generates all passwords and encryption keys, and writes both `.env` files for you:

```bash
./setup.sh
```

You can also do it manually if you prefer. Copy `.env.example` to `.env` (and `monitoring/.env.example` to `monitoring/.env`) and fill in the values. Generate encryption keys with `openssl rand -hex 32`.

### 2. Start the app stack

```bash
docker compose up -d
```

This brings up n8n, Postgres, Redis, Traefik, the socket proxy, and the backup service. It also creates the Docker networks that the monitoring stack connects to.

Wait about 30 seconds for health checks to settle:

```bash
docker compose ps
docker compose logs -f n8n
```

Once healthy, open `https://<your-host>` and create your first admin account.

### 3. Start the monitoring stack

```bash
cd monitoring
docker compose up -d
```

The setup script already created `monitoring/.env`. Grafana is at `https://<your-host>/grafana/` with Prometheus pre-wired as a data source.

## Project Structure

```
hardened-n8n-setup/
|-- .env.example                              App stack config template
|-- .gitignore
|-- setup.sh                                  Interactive setup, generates .env files
|-- docker-compose.yml                        App stack (n8n + infra)
|-- config/
|   |-- prometheus/
|   |   +-- prometheus.yml                    Scrape targets
|   +-- grafana/
|       +-- provisioning/
|           +-- datasources/
|               +-- prometheus.yml            Auto-provisions Prometheus in Grafana
+-- monitoring/
    |-- .env.example                          Monitoring config template
    +-- docker-compose.yml                    Prometheus + Grafana + exporters
```

## Security Details

Every container follows the same hardening approach.

### Filesystem

- Read-only root filesystem on all containers
- Writable paths limited to named volumes and explicit tmpfs mounts
- All tmpfs mounts set to `noexec,nosuid`

### Process Isolation

- All Linux capabilities dropped (`cap_drop: ALL`), re-added only where needed
- `no-new-privileges` on every container
- Non-root users with explicit UID/GID everywhere

### Docker Socket

The Docker socket is never exposed directly to Traefik. Instead, a dedicated socket proxy ([tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) sits between them:

- The proxy mounts the socket read-only
- Only the API endpoints Traefik needs are allowed (containers, networks, services, version, info)
- Everything else is blocked: no exec, no image builds, no volume access, no POST requests
- Traefik talks to the proxy over an internal network, never touches the socket

This matters because the Docker socket is effectively root access to the host. Giving it directly to Traefik (even read-only) means a Traefik compromise could read sensitive container info. The proxy limits the blast radius.

### Network Isolation

- Backend services (Postgres, Redis) have zero internet access
- Only Traefik publishes ports to the host
- Each service joins only the networks it actually needs

### Resource Limits

- CPU and memory caps on every container
- Prevents any single service from starving the host

### Traefik

- Dashboard disabled
- `exposedbydefault=false` -- new containers are not auto-exposed
- HSTS with preloading, XSS filter, frame denial, content-type sniffing prevention
- Rate limiting: 100 requests/minute, burst tolerance of 50
- Referrer and permissions policies locked down

### Redis

- `FLUSHDB`, `FLUSHALL`, `DEBUG` commands disabled (renamed to empty strings)
- Protected mode on
- Memory capped at 128MB with LRU eviction

## Backups

The `pg-backup` service runs automated `pg_dump` daily:

| Retention | Default |
|-----------|---------|
| Daily | 7 days |
| Weekly | 4 weeks |
| Monthly | 6 months |

Backups live in the `pg_backups` Docker volume. Pull them to the host:

```bash
docker cp n8n-pg-backup:/backups ./backups
```

**Manual backup:**

```bash
docker exec n8n-postgres pg_dump -U n8n -d n8n > backup_$(date +%Y%m%d).sql
```

**Restore:**

```bash
cat backup.sql | docker exec -i n8n-postgres psql -U n8n -d n8n
```

## Monitoring

The monitoring stack is a separate Compose project on purpose. It connects to the app stack's networks but has its own lifecycle. You can tear it down, restart it, or swap components without touching n8n. If you add more n8n instances later, one monitoring stack watches them all.

### Scrape Targets

| Target | Endpoint | Port |
|--------|----------|------|
| n8n | `/metrics` | 5678 |
| Traefik | `/metrics` | 8082 (internal) |
| PostgreSQL | via postgres-exporter | 9187 |
| Redis | via redis-exporter | 9121 |

### Grafana Dashboards

Prometheus is auto-provisioned. Import these dashboard IDs for a quick start:

- **PostgreSQL**: `9628`
- **Redis**: `11835`
- **Traefik**: `17346`
- **n8n**: Check the [n8n docs](https://docs.n8n.io) for their official JSON

Grafana UI > Dashboards > Import > paste the ID.

## Updating

**n8n:**

```bash
docker compose pull n8n
docker compose up -d n8n
```

For production, pin to a version tag instead of `latest`:

```yaml
image: n8nio/n8n:1.82.1
```

**Monitoring:**

```bash
cd monitoring
docker compose pull
docker compose up -d
```

## Platform Notes

### This stack targets Linux

All hardening features (read-only filesystems, capability dropping, socket proxy, non-root users) work natively on Linux with Docker Engine. That's where this is designed to run.

### macOS (Docker Desktop) has issues

Docker Desktop on macOS runs containers inside a hidden Linux VM. This introduces several problems with a hardened setup:

- **Docker socket**: Docker Desktop proxies the socket through its VM layer. The socket proxy and Traefik can fail with empty API errors (`"Error response from daemon: ""`) because of how Docker Desktop handles API version negotiation. The minimum API version on recent Docker Desktop (v4.60+) is 1.44, but Traefik's Go client starts negotiation at 1.24, which gets rejected before it can upgrade.
- **File permissions**: UID/GID mappings behave differently because of the macOS-to-Linux VM translation layer. Containers that work fine on native Linux can hit permission errors on Desktop.
- **Read-only filesystems**: Some containers that run fine with `read_only: true` on Linux will fail on Docker Desktop due to how the VM handles tmpfs and bind mounts.

If you want to develop or test on a Mac, run a Linux VM (UTM, Parallels, or VirtualBox) with Docker Engine installed natively. That gives you the same behavior as production and avoids all of these issues.

### Windows (WSL2)

Should work inside a WSL2 distribution with Docker Engine (not Docker Desktop). Not tested, but the same Linux-native behavior applies.

## Troubleshooting

**n8n won't start, database connection errors**

Postgres might still be starting up. Check health and logs:

```bash
docker compose ps postgres
docker compose logs postgres
```

**Let's Encrypt cert not issued**

Only applies if you chose domain mode. Port 80 must be reachable from the public internet for the HTTP-01 challenge:

```bash
docker compose logs traefik | grep acme
```

**Browser shows certificate warning**

Expected with self-signed TLS (IP/localhost mode). The encryption is real, same strength as Let's Encrypt. Accept and continue.

**Grafana shows "No data"**

Start the app stack first. It creates the networks the monitoring stack connects to.

**Socket proxy errors**

If Traefik logs show errors reaching the socket proxy, check that the proxy is running:

```bash
docker compose ps socket-proxy
docker compose logs socket-proxy
```

## License

MIT
