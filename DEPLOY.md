# Deploying Replicant Server with Kamal

Deployment target: Digital Ocean droplet via Kamal v2.

## Current Setup

- **Droplet**: `<DROPLET_IP>` (Ubuntu 24.04, 2GB RAM)
- **Domain**: `<YOUR_DOMAIN>` (SSL via kamal-proxy)
- **Registry**: `ghcr.io/<YOUR_ORG>`
- **Database**: Postgres 16 (Kamal accessory on same droplet)
- **Elixir**: 1.19.4 / OTP 27 / Alpine 3.21.6

## Prerequisites

- **Docker running locally** — Kamal needs it even for remote operations
- **Kamal installed** — `gem install kamal` (v2.10+)
- **SSH access** to the droplet as root

## Deploying

```bash
kamal deploy
```

That's it. Kamal builds the image remotely on the droplet, pushes to GHCR, and does a zero-downtime container swap.

## First-Time Setup

### 1. Digital Ocean Resources

- **Droplet**: Ubuntu 24.04, 2GB RAM minimum
- **DNS**: A record pointing domain to droplet IP

### 2. GitHub Container Registry

Create a **classic** Personal Access Token at https://github.com/settings/tokens with scopes:
- `write:packages`
- `read:packages`

### 3. Configuration Files

```bash
cp config/deploy.yml.example config/deploy.yml
cp .kamal/secrets.example .kamal/secrets
```

Fill in `.kamal/secrets` with real values. Generate the Phoenix secret with:

```bash
mix phx.gen.secret
```

Both `config/deploy.yml` and `.kamal/secrets` are gitignored.

### 4. Registry Login on Droplet

```bash
ssh root@<DROPLET_IP> "docker login ghcr.io -u YOUR_GITHUB_USERNAME -p YOUR_GITHUB_PAT"
```

### 5. Initial Infrastructure

First deploy — sets up kamal-proxy, Postgres, and the app:

```bash
kamal setup
```

### 6. Verify

```bash
curl https://<YOUR_DOMAIN>/health
# {"status":"ok"}
```

## Database Migrations

```bash
kamal app exec -i --reuse "bin/replicant_server eval 'ReplicantServer.Release.migrate()'"
```

## Useful Commands

```bash
# Deploy
kamal deploy

# Check app logs
kamal app logs

# Check app status
kamal app details

# SSH into running container
kamal app exec -i --reuse sh

# Restart the app
kamal app boot

# Reboot Postgres
kamal accessory reboot db

# Postgres logs
kamal accessory logs db

# Check what's running on the droplet
ssh root@<DROPLET_IP> "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Release a stuck deploy lock
kamal lock release
```

## Pitfalls

### "Cannot connect to Docker daemon" locally

Kamal needs a local Docker daemon running even for remote operations. Use Docker Desktop or `colima start`.

### Image name double-prefixed with registry

The `image` field in `deploy.yml` should NOT include the registry server:

```yaml
# Wrong
image: ghcr.io/<YOUR_ORG>/replicant-server

# Correct
image: <YOUR_ORG>/replicant-server
```

### force_ssl breaks deploys

Phoenix `force_ssl` is disabled in `prod.exs` — kamal-proxy handles SSL termination instead.

### DO Container Registry + BuildKit

DigitalOcean's container registry is incompatible with BuildKit's auth mechanism (returns `405 Method Not Allowed`). This is why we use GitHub Container Registry instead.
