# Quay Container Registry — Quadlet Deployment

Self-hosted [Project Quay](https://github.com/quay/quay) container registry running as Podman Quadlet systemd units. TLS is terminated directly by Quay (no reverse proxy).

## Architecture

```
Client ──HTTPS:8443──► Quay  (ssl.cert + ssl.key in config dir)
Client ──HTTP:8080 ──► Quay  (unencrypted, internal use only)
                         │
                 ┌───────┴────────┐
          PostgreSQL:5433      Redis:6379
         (quay-postgres)      (quay-redis)
```

All three services run in **host network** mode as Podman Quadlet containers managed by systemd.

| Service | Image | Unit file |
|---|---|---|
| Quay | `quay.io/projectquay/quay:latest` | `quay.container` |
| PostgreSQL | `docker.io/library/postgres:15` | `quay-postgres.container` |
| Redis | `docker.io/library/redis:7` | `quay-redis.container` |

## Directory layout

```
quay-quadlet/quay/
├── configs/
│   └── config.yaml            # Quay application config (edit before deploying)
├── quay.container             # Quadlet unit for Quay
├── quay-postgres.container    # Quadlet unit for PostgreSQL
├── quay-redis.container       # Quadlet unit for Redis
├── deploy-quay-local.sh       # Deploy on the machine you run the script on
├── deploy-quay-remote.sh      # Deploy to a remote server over SSH
├── setup_letsencrypt.sh       # Obtain TLS cert via Certbot + Cloudflare DNS
├── setup_renewal.sh           # Configure automatic cert renewal
└── cloudflare.ini             # Cloudflare API token for DNS-01 challenge
```

Data directories created on the host at deploy time:

| Path | Purpose |
|---|---|
| `/home/arvin/app-data/quay/config` | `config.yaml`, `ssl.cert`, `ssl.key` |
| `/home/arvin/app-data/quay/storage` | OCI blob / image layer storage |
| `/home/arvin/app-data/quay/postgres` | PostgreSQL data (owned by UID 999) |

## Pre-deployment checklist

1. **Generate secrets** and update `configs/config.yaml`:

   ```bash
   openssl rand -hex 32   # run twice — once for DATABASE_SECRET_KEY, once for SECRET_KEY
   ```

   Values to set in `configs/config.yaml`:

   | Key | Description |
   |---|---|
   | `DATABASE_SECRET_KEY` | Random 64-char hex string |
   | `SECRET_KEY` | Random 64-char hex string |
   | `DB_URI` | PostgreSQL DSN — password must match step 2 |
   | `SERVER_HOSTNAME` | Public FQDN, e.g. `quay.arvhomelab.com:8443` |

2. **Set the database password** in `quay-postgres.container`:

   ```ini
   Environment=POSTGRES_PASSWORD=<same password as in DB_URI>
   ```

3. **Populate `cloudflare.ini`** with a Cloudflare API token scoped to DNS edit on your zone (needed by `setup_letsencrypt.sh`):

   ```ini
   dns_cloudflare_api_token = <your-token>
   ```

## Deploying

### On the local machine

```bash
./deploy-quay-local.sh
```

With optional admin user creation on first deploy:

```bash
QUAY_ADMIN_PASSWORD='yourpassword' ./deploy-quay-local.sh
```

### To a remote server over SSH

```bash
./deploy-quay-remote.sh              # deploys to all configured servers
./deploy-quay-remote.sh infra-lb1    # deploys to a specific server
```

With optional admin user creation:

```bash
QUAY_ADMIN_PASSWORD='yourpassword' ./deploy-quay-remote.sh
```

Both scripts:
1. Copy the Quadlet unit files to `/etc/containers/systemd/`
2. Create data directories and install `config.yaml`
3. Copy Let's Encrypt scripts and Cloudflare credentials to `$APP_DATA_DIR`
4. Reload systemd and start services in dependency order (postgres → redis → quay)
5. Wait for each service to become healthy before proceeding
6. Run smoke tests against the HTTP/HTTPS endpoints

## TLS certificates

TLS is terminated directly by Quay. Certificates live in the config directory as `ssl.cert` and `ssl.key`.

**First-time setup** (after deploying):

```bash
cd /home/arvin/app-data/quay
./setup_letsencrypt.sh    # obtains cert via Certbot DNS-01 + Cloudflare, installs into config dir
./setup_renewal.sh        # registers a certbot deploy hook to restart quay on renewal
```

Until certificates are installed Quay serves HTTP only on port 8080.

## Service management

```bash
# Status
systemctl status quay-postgres.service quay-redis.service quay.service

# Logs
sudo journalctl -u quay.service -f
sudo journalctl -u quay-postgres.service -f

# Restart
sudo systemctl restart quay-postgres.service quay-redis.service quay.service

# Stop (reverse dependency order)
sudo systemctl stop quay.service quay-redis.service quay-postgres.service
```

## Using the registry

```bash
# Login
podman login quay.arvhomelab.com:8443

# Pull through the proxy cache
podman pull quay.arvhomelab.com/docker.io/library/nginx:latest

# Push an image
podman tag myimage:latest quay.arvhomelab.com/<org>/<repo>:latest
podman push quay.arvhomelab.com/<org>/<repo>:latest
```

Web UI: **https://quay.arvhomelab.com**

## Notable configuration

| Setting | Value |
|---|---|
| `PREFERRED_URL_SCHEME` | `https` |
| `EXTERNAL_TLS_TERMINATION` | `false` (Quay handles TLS) |
| `FEATURE_ANONYMOUS_ACCESS` | `false` |
| `FEATURE_USER_CREATION` | `true` |
| `MAXIMUM_LAYER_SIZE` | `20G` |
| `DEFAULT_TAG_EXPIRATION` | `2w` |
| PostgreSQL port | `5433` (non-default, avoids conflicts) |
| Redis port | `6379` |
