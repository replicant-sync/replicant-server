# Deployment Guide

This guide covers deploying the Replicant sync server using [Kamal](https://kamal-deploy.org/).

## Prerequisites

- A Linux server (VPS) with SSH access
- Docker Hub account (or other container registry)
- Domain name pointing to your server
- Ruby installed locally (for Kamal CLI)

## Install Kamal

```bash
gem install kamal
```

Or use Docker-based Kamal (no Ruby needed):
```bash
alias kamal='docker run -it --rm -v "${PWD}:/workdir" -v "${SSH_AUTH_SOCK}:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent ghcr.io/basecamp/kamal:latest'
```

## Configuration

### 1. Create deploy.yml

Copy the template and customize:

```bash
cp config/deploy.yml.example config/deploy.yml
```

Edit `config/deploy.yml` and replace:
- `your-dockerhub-username` → your Docker Hub username
- `your-server-ip` → your server's IP address
- `your-domain.com` → your domain
- `your-email@example.com` → your email (for Let's Encrypt SSL)

### 2. Set Up Secrets

Create the secrets file:

```bash
cp .kamal/secrets.example .kamal/secrets
```

Edit `.kamal/secrets` with your values:

```bash
# Generate a secret key base
mix phx.gen.secret

# Use the output for SECRET_KEY_BASE in .kamal/secrets
```

Required secrets:
- `KAMAL_REGISTRY_PASSWORD` - Docker Hub password or access token
- `POSTGRES_PASSWORD` - PostgreSQL password (choose a secure one)
- `SECRET_KEY_BASE` - Phoenix secret (generate with `mix phx.gen.secret`)
- `DATABASE_URL` - Full database connection string

### 3. Server Preparation

Ensure your server has:
- SSH access configured (key-based auth recommended)
- Port 80 and 443 open for HTTP/HTTPS
- Port 22 open for SSH

Kamal will automatically install Docker on first deploy.

## Deployment

### First-Time Setup

```bash
cd replicant-server
kamal setup
```

This will:
- Install Docker on your server
- Start Traefik (reverse proxy with SSL)
- Start PostgreSQL
- Build and deploy the app
- Run database migrations

### Subsequent Deploys

```bash
kamal deploy
```

### Useful Commands

```bash
kamal app logs          # View application logs
kamal app logs -f       # Follow logs
kamal traefik logs      # View Traefik logs
kamal accessory logs db # View PostgreSQL logs

kamal app exec --interactive 'bin/replicant_server remote'  # IEx console
kamal app exec 'bin/migrate'  # Run migrations manually

kamal rollback          # Rollback to previous version
```

## Production Checklist

- [ ] Domain DNS pointing to server IP
- [ ] Strong `POSTGRES_PASSWORD` set
- [ ] `SECRET_KEY_BASE` generated and set
- [ ] SSL certificate provisioned (automatic via Let's Encrypt)
- [ ] Firewall configured (ports 80, 443, 22)
- [ ] Backups configured for PostgreSQL data

## Architecture

```
┌─────────────────────────────────────────────┐
│                   Server                     │
│  ┌─────────────────────────────────────┐    │
│  │           Traefik (443/80)          │    │
│  │         SSL termination             │    │
│  └──────────────┬──────────────────────┘    │
│                 │                            │
│  ┌──────────────▼──────────────────────┐    │
│  │     replicant-server (4000)         │    │
│  │     Phoenix + WebSocket             │    │
│  └──────────────┬──────────────────────┘    │
│                 │                            │
│  ┌──────────────▼──────────────────────┐    │
│  │      PostgreSQL (5432)              │    │
│  │      /var/lib/postgresql/data       │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

## Troubleshooting

### Container won't start
```bash
kamal app logs
kamal app details
```

### Database connection issues
```bash
kamal accessory logs db
kamal accessory exec db 'psql -U postgres -c "\l"'
```

### SSL certificate issues
```bash
kamal traefik logs
# Ensure domain DNS is properly configured
# Let's Encrypt needs to reach your server on port 80
```

### Health check failing
```bash
curl http://your-server-ip:4000/health
```
