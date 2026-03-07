# Deploying Replicant Server with Kamal

Deployment target: Digital Ocean droplet via Kamal v2.

## Prerequisites

- **Docker running locally** — Kamal needs a local Docker daemon even for remote builds. Use Docker Desktop or `colima start`.
- **Kamal installed** — `gem install kamal` (v2.10+)
- **SSH access** to the droplet as root

## Setup

### 1. Digital Ocean Resources

- **Droplet**: Ubuntu 24.04, 2GB RAM minimum (1GB is too tight with Postgres + Phoenix + Docker on same machine)
- **Container Registry**: One registry per org (e.g. `node-audio`), not per project
- **DNS**: A record pointing your domain to the droplet IP

### 2. API Token

Create a DO API token at API → Tokens → Generate New Token.

- Granular scopes don't currently support container image push — **use Full Access**
- Same token is used as both registry username and password

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

### 4. Deploy

```bash
kamal setup    # First deploy — installs Docker, kamal-proxy, Postgres, app
kamal deploy   # Subsequent deploys
```

### 5. Verify

```bash
curl https://your-domain.com/health
```

## Pitfalls

### Remote builder can't push to DO registry

**Symptom**: `405 Method Not Allowed` from `https://api.digitalocean.com/v2/registry/auth`

The buildx `docker-container` driver runs in its own container and doesn't inherit the host's `~/.docker/config.json`. Fix by logging into the registry on the droplet:

```bash
ssh root@YOUR_IP "docker login registry.digitalocean.com -u YOUR_TOKEN -p YOUR_TOKEN"
```

Then reset the builder to use the default `docker` driver:

```bash
ssh root@YOUR_IP "docker buildx rm kamal-remote-ssh---root-YOUR_IP 2>/dev/null"
```

Kamal will recreate it on next deploy.

### "Cannot connect to Docker daemon" locally

**Symptom**: `Cannot connect to the Docker daemon at unix:///Users/.../.docker/run/docker.sock`

Kamal runs `docker buildx build` locally even with remote building — the local Docker CLI orchestrates the remote build over SSH. **You must have Docker running locally** (Docker Desktop or `colima start`).

### Image name double-prefixed with registry

**Symptom**: Push to `registry.digitalocean.com/registry.digitalocean.com/...`

The `image` field in `deploy.yml` should NOT include the registry server — Kamal prepends it from the `registry.server` field:

```yaml
# Wrong
image: registry.digitalocean.com/node-audio/replicant-server

# Correct
image: node-audio/replicant-server
```

### Dockerfile warnings on remote builder

**Symptom**: Warnings about `FromAsCasing` and `LegacyKeyValueFormat` even after fixing the Dockerfile locally.

The remote builder caches layers aggressively. These are warnings, not errors — they don't block the build. They resolve once a layer cache miss forces a rebuild.

### force_ssl breaks IP-only deploys

Phoenix `force_ssl` is a compile-time setting in `prod.exs`. If enabled, it redirects all HTTP to HTTPS, which breaks deploys to a bare IP without SSL. Currently disabled — kamal-proxy handles SSL termination instead.

### DO granular API token scopes

The "registry" scope controls managing registries (create/delete), not pushing images. As of March 2026, there's no granular scope for container image push. Use Full Access.
