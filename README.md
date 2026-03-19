# n8n Self-Hosted (Hardened)

A production-ready, security-first n8n deployment using Docker Compose. Every container is locked down: read-only filesystems, dropped capabilities, non-root users, isolated networks, resource limits. No shortcuts.

Two deployment paths: run it on your own Linux box, or provision a hardened GCP VM with one command. Same security posture either way.

![Containers](https://img.shields.io/badge/containers-10-blue)
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
| **Grafana** | Dashboards and alerting (localhost only, SSH tunnel access) |
| **Postgres Exporter** | DB metrics for Prometheus |
| **Redis Exporter** | Cache metrics for Prometheus |

## Architecture

```
                  Internet
                     |
              +------+------+
              |   Traefik   |  :80 (redirect) + :443 (TLS)
              +------+------+
                     | n8n-frontend
                     v
              +--------------+
              |     n8n      |
              |   :5678      |
              +------+-------+
                     | n8n-backend (internal)
              +------+-------+
              |  PostgreSQL  |
              |  Redis       |
              |  pg-backup   |
              +--------------+

         n8n-monitoring (internal)
              +--------------+
              |  Prometheus  |
              |  Exporters   |
              +------+-------+
                     |
              +------+-------+
              |   Grafana    |  127.0.0.1:3000 (SSH tunnel only)
              +--------------+
```

**Four isolated networks:**

- **n8n-socket** (internal) -- Socket proxy talks to Traefik. Nothing else.
- **n8n-backend** (internal, no internet) -- Postgres, Redis, n8n, backup, exporters.
- **n8n-frontend** (bridged) -- Traefik and n8n. Only Traefik publishes ports.
- **n8n-monitoring** (internal, no internet) -- Prometheus, Grafana, exporters.

Grafana is **not** exposed through Traefik. It binds to `127.0.0.1:3000` only and is accessed via SSH tunnel. This keeps your monitoring dashboard off the public internet entirely.

## TLS

TLS is always on. You choose how certificates are handled:

| Mode | When to use | How it works |
|------|-------------|--------------|
| **Domain** | You have a domain pointed at the server | Traefik gets a Let's Encrypt cert automatically |
| **IP / localhost** | On-prem, LAN, no domain | Traefik uses its built-in self-signed cert |

Both use the same encryption strength. The difference is trust: Let's Encrypt certs are signed by a public CA so browsers trust them silently. Self-signed certs trigger a browser warning you click through once. On a LAN or known IP, that's fine.

## Prerequisites

- **Linux** server or VM (Ubuntu 22.04+, Debian 12+, or similar)
- Docker Engine and Docker Compose v2
- Ports 80 and 443 available
- A domain pointed at the server (only if you want Let's Encrypt)

> **Why Linux and not macOS?** See [Platform Notes](#platform-notes) below.

---

## Deployment

Pick your path:

| Path | Best for | What it does |
|------|----------|--------------|
| [Local / On-Prem](#option-a-local--on-prem) | Your own Linux server, VM, homelab | Interactive setup, you manage the box |
| [GCP (automated)](#option-b-deploy-to-gcp) | Cloud deployment | Provisions a hardened VM with networking, runs everything automatically |

---

### Option A: Local / On-Prem

For any Linux machine you control: a bare-metal server, a VM, a VPS, whatever. You run the setup script, it asks a few questions, generates secrets, and you bring the stack up.

#### 1. Clone and configure

```bash
git clone https://github.com/MarcusScipio/hardened-n8n-setup.git
cd hardened-n8n-setup
```

Run the interactive setup script. It walks you through TLS mode, generates all passwords and encryption keys, and writes both `.env` files:

```bash
./setup.sh
```

Or do it manually: copy `.env.example` to `.env` (and `monitoring/.env.example` to `monitoring/.env`) and fill in the values. Generate encryption keys with `openssl rand -hex 32`.

#### 2. Start the app stack

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

#### 3. Start the monitoring stack

```bash
cd monitoring
docker compose up -d
```

#### 4. Access Grafana

Grafana binds to `localhost:3000` only. If you're on the machine, just open `http://localhost:3000`.

From a remote machine, use an SSH tunnel:

```bash
ssh -L 3000:localhost:3000 user@your-server
```

Then open `http://localhost:3000` in your browser. Prometheus is pre-wired as a data source.

---

### Option B: Deploy to GCP

One script provisions everything: a dedicated VPC, private subnet, Cloud Router, NAT gateway, scoped firewall rules, and a hardened Ubuntu VM that bootstraps itself.

#### What gets created

| Resource | Details |
|----------|---------|
| **VPC** | `n8n-vpc`, custom mode, no default subnets |
| **Subnet** | `n8n-subnet`, `10.10.0.0/24`, private Google access |
| **Cloud Router + NAT** | Outbound internet for the VM |
| **Firewall: SSH** | Port 22 from IAP range only (`35.235.240.0/20`) |
| **Firewall: HTTP/HTTPS** | Ports 80 + 443 from anywhere |
| **Firewall: deny-all** | Explicit catch-all deny on everything else |
| **VM** | Ubuntu 22.04, Shielded VM (secure boot, vTPM, integrity monitoring) |

#### Prerequisites

- `gcloud` CLI installed and authenticated
- A GCP project with Compute Engine API enabled
- Service account with these roles:
  - **Compute Admin** (VM and firewall management)
  - **Network Admin** (VPC, subnet, router, NAT)
  - **IAP-secured Tunnel User** (SSH access via IAP, used by CI/CD)

#### Provision

```bash
# Self-signed TLS (no domain)
./infra/provision-gcp.sh

# Let's Encrypt (with domain)
./infra/provision-gcp.sh -d n8n.example.com -e you@email.com
```

| Flag | Description | Default |
|------|-------------|---------|
| `-d` | Domain name pointed at the VM | (none, uses IP) |
| `-e` | Email for Let's Encrypt | (required with `-d`) |
| `-r` | GCP region | `europe-west1` |
| `-z` | GCP zone | `europe-west1-b` |
| `-m` | Machine type | `e2-small` |
| `-n` | VM name | `n8n-server` |
| `-p` | GCP project ID | current gcloud config |

The bootstrap script runs automatically on the VM: installs Docker, clones this repo, generates `.env` with random secrets, and starts both stacks. Takes 2-3 minutes.

#### Check progress

```bash
gcloud compute ssh n8n-server --zone=europe-west1-b --tunnel-through-iap
sudo tail -f /var/log/n8n-bootstrap.log
```

#### Access Grafana (GCP)

Grafana is not exposed publicly. Access it through an IAP SSH tunnel:

```bash
gcloud compute ssh n8n-server --zone=europe-west1-b --tunnel-through-iap -- -L 3000:localhost:3000
```

Then open `http://localhost:3000`. Credentials are in `/opt/n8n/monitoring/.env` on the VM.

#### CI/CD with GitHub Actions

The pipeline handles everything. If the VM doesn't exist, it provisions the full infrastructure (VPC, firewall, NAT, VM) and waits for the bootstrap to complete. If the VM already exists, it SSHs in, pulls latest code, and redeploys. One click, either way.

**Triggers:**

- Automatic on every push to `main`
- Manual via the **"Run workflow"** button in the Actions tab

**Setup:**

1. In your GitHub repo, go to Settings > Environments
2. Create an environment named `GCP_SA_KEY`
3. Add a **secret** named `GCP_SA_KEY` with the full service account JSON key
4. Optionally add **variables** to override defaults:

| Variable | Description | Default |
|----------|-------------|---------|
| `VM_NAME` | VM instance name | `n8n-server` |
| `GCP_ZONE` | GCP zone | `europe-west1-b` |
| `GCP_REGION` | GCP region | `europe-west1` |
| `GCP_MACHINE` | Machine type | `e2-small` |
| `N8N_DOMAIN` | Domain for Let's Encrypt | (none, uses IP) |
| `ACME_EMAIL` | Email for Let's Encrypt | (none) |

If you don't set any variables, everything uses sensible defaults and the VM gets self-signed TLS on its external IP.

#### SSH access

```bash
gcloud compute ssh n8n-server --zone=europe-west1-b --tunnel-through-iap
```

Everything lives in `/opt/n8n` on the VM. The `.env` files are generated there and never leave the machine.

---

## Project Structure

```
hardened-n8n-setup/
|-- .env.example                              App stack config template
|-- .gitignore
|-- setup.sh                                  Interactive setup (local/on-prem)
|-- docker-compose.yml                        App stack (n8n + infra)
|-- config/
|   |-- prometheus/
|   |   +-- prometheus.yml                    Scrape targets
|   +-- grafana/
|       +-- provisioning/
|           +-- datasources/
|               +-- prometheus.yml            Auto-provisions Prometheus in Grafana
|-- infra/
|   |-- bootstrap.sh                          VM startup script (GCP automated deploy)
|   +-- provision-gcp.sh                      Creates VPC + VM with one command
|-- .github/
|   +-- workflows/
|       +-- deploy.yml                        CD pipeline (push to main -> deploy)
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
- Grafana binds to localhost only, never exposed publicly
- Each service joins only the networks it actually needs

### GCP Network Security

When deployed to GCP, the provisioning script creates:

- A dedicated VPC (not the default network)
- SSH access restricted to Google's IAP range (no direct SSH from the internet)
- Only ports 80 and 443 open inbound
- Explicit deny-all catch-all rule
- Cloud NAT for outbound traffic
- Shielded VM with secure boot, vTPM, and integrity monitoring

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

The monitoring stack is a separate Compose project on purpose. It connects to the app stack's networks but has its own lifecycle. You can tear it down, restart it, or swap components without touching n8n.

Grafana is accessible on `localhost:3000` only. On a remote server, use SSH tunnel (see deployment sections above).

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
