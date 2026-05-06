#!/bin/bash

# Script to deploy Quay container registry on the local machine
# This script:
# 1. Deploys quay-postgres, quay-redis, quay .container files to /etc/containers/systemd/
# 2. Copies config.yaml to /home/mariam/app-data/quay/config
# 3. Optionally installs user-provided TLS certificates
# 4. Creates data, storage, postgres, and redis dirs
# 5. Reloads systemd, starts the services in order, and tests them
#
# TLS is terminated directly by Quay (ssl.cert + ssl.key in config dir).
# Pass --cert and --key to install your own certificates during deployment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source files
POSTGRES_CONTAINER_FILE="quay-postgres.container"
REDIS_CONTAINER_FILE="quay-redis.container"
QUAY_CONTAINER_FILE="quay.container"
CONFIG_DIR="configs"

# Local paths
APP_DATA_DIR="/home/mariam/app-data/quay"
CONFIG_DEST_DIR="${APP_DATA_DIR}/config"
STORAGE_DIR="${APP_DATA_DIR}/storage"
POSTGRES_DIR="${APP_DATA_DIR}/postgres"

# Certificate paths (optional, provided via --cert / --key)
CERT_FILE=""
KEY_FILE=""

usage() {
    echo "Usage: $0 [-h|--help] [--cert <cert-file>] [--key <key-file>]"
    echo
    echo "Deploy Quay container registry with direct TLS (no HAProxy) on the local machine."
    echo
    echo "Options:"
    echo "  --cert <file>   Path to the TLS certificate file (PEM) to install as ssl.cert"
    echo "  --key  <file>   Path to the TLS private key file (PEM) to install as ssl.key"
    echo "  -h, --help      Show this help message"
    echo
    echo "Architecture:"
    echo "  Client --HTTPS:8443--> Quay nginx (ssl.cert + ssl.key in config dir)"
    echo "  Client --HTTP:8080 --> Quay nginx (unencrypted, internal use only)"
    echo "  PostgreSQL and Redis are internal only"
    echo
    echo "Pre-deployment (edit configs/config.yaml first):"
    echo "  1. Generate secrets: openssl rand -hex 32"
    echo "  2. Set DATABASE_SECRET_KEY, SECRET_KEY, and DB_URI password"
    echo "  3. Update POSTGRES_PASSWORD in quay-postgres.container to match DB_URI"
    echo
    echo "Admin user creation (first deploy only):"
    echo "  QUAY_ADMIN_PASSWORD='yourpassword' $0 --cert /path/to/ssl.cert --key /path/to/ssl.key"
    echo "  (Skipped automatically if admin user already exists)"
    echo
    echo "Pull images through the registry:"
    echo "  podman pull quay.arvhomelab.com/docker.io/library/nginx:latest"
    echo
    echo "Check service status:"
    echo "  systemctl status quay-postgres.service quay-redis.service quay.service"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --cert)
            CERT_FILE="${2:-}"
            shift 2
            ;;
        --key)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        *)
            echo "✗ ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate cert/key: must be provided together
if [ -n "$CERT_FILE" ] && [ -z "$KEY_FILE" ]; then
    echo "✗ ERROR: --cert requires --key to also be specified"
    exit 1
fi
if [ -z "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
    echo "✗ ERROR: --key requires --cert to also be specified"
    exit 1
fi
if [ -n "$CERT_FILE" ] && [ ! -f "$CERT_FILE" ]; then
    echo "✗ ERROR: Certificate file not found: $CERT_FILE"
    exit 1
fi
if [ -n "$KEY_FILE" ] && [ ! -f "$KEY_FILE" ]; then
    echo "✗ ERROR: Key file not found: $KEY_FILE"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

echo "=== Deploying Quay container registry (local) ==="
echo "Server IP: $SERVER_IP"
echo

echo "Checking source files..."
for f in "$POSTGRES_CONTAINER_FILE" "$REDIS_CONTAINER_FILE" "$QUAY_CONTAINER_FILE"; do
    if [ ! -f "$f" ]; then
        echo "✗ ERROR: Source file '$f' not found in $SCRIPT_DIR"
        exit 1
    fi
done
if [ ! -d "$CONFIG_DIR" ]; then
    echo "✗ ERROR: Config directory '$CONFIG_DIR' not found in $SCRIPT_DIR"
    exit 1
fi
echo "✓ All source files found"
echo

echo "Installing container unit files..."
sudo cp "$POSTGRES_CONTAINER_FILE" "/etc/containers/systemd/$POSTGRES_CONTAINER_FILE"
sudo cp "$REDIS_CONTAINER_FILE"    "/etc/containers/systemd/$REDIS_CONTAINER_FILE"
sudo cp "$QUAY_CONTAINER_FILE"     "/etc/containers/systemd/$QUAY_CONTAINER_FILE"
echo "✓ Copied container files to /etc/containers/systemd/"

echo "Creating directories..."
mkdir -p "$CONFIG_DEST_DIR"
mkdir -p "$STORAGE_DIR"
mkdir -p "$POSTGRES_DIR"
echo "✓ Created $APP_DATA_DIR"

echo "Installing Quay configuration files..."
cp "$CONFIG_DIR/config.yaml" "$CONFIG_DEST_DIR/config.yaml"
echo "✓ Copied Quay config to $CONFIG_DEST_DIR"

if [ -n "$CERT_FILE" ]; then
    echo "Installing TLS certificates..."
    cp "$CERT_FILE" "$CONFIG_DEST_DIR/ssl.cert"
    cp "$KEY_FILE"  "$CONFIG_DEST_DIR/ssl.key"
    chmod 644 "$CONFIG_DEST_DIR/ssl.cert"
    chmod 644 "$CONFIG_DEST_DIR/ssl.key"
    echo "✓ Installed ssl.cert and ssl.key into $CONFIG_DEST_DIR"
fi

echo "Setting permissions..."
sudo chown -R mariam:mariam "$APP_DATA_DIR"
chmod 644 "$CONFIG_DEST_DIR/config.yaml"
echo "✓ Permissions set"

echo "Fixing postgres data directory ownership (UID 999 = postgres inside container)..."
sudo chown -R 999:999 "$POSTGRES_DIR"
echo "✓ Postgres data directory ownership set"

echo "Configuring SELinux..."
SELINUX_XATTR_OK=false
if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    # Allow containers to read/write the bind-mounted data directories
    if sudo chcon -Rt container_file_t "$APP_DATA_DIR" 2>/dev/null; then
        SELINUX_XATTR_OK=true
        echo "✓ SELinux: chcon applied to $APP_DATA_DIR"
        sudo semanage fcontext -a -t container_file_t "${APP_DATA_DIR}(/.*)?" 2>/dev/null || \
            sudo semanage fcontext -m -t container_file_t "${APP_DATA_DIR}(/.*)?"
        sudo restorecon -Rv "$APP_DATA_DIR" 2>/dev/null || true
    else
        echo "⚠ SELinux: filesystem does not support xattrs — disabling SELinux label enforcement for containers"
        # Remove :Z volume label flags and add --security-opt label=disable so containers
        # are not blocked from accessing mounts on filesystems without xattr support
        for f in "/etc/containers/systemd/$QUAY_CONTAINER_FILE" \
                 "/etc/containers/systemd/$POSTGRES_CONTAINER_FILE" \
                 "/etc/containers/systemd/$REDIS_CONTAINER_FILE"; do
            sudo sed -i 's/:Z\b//g' "$f"
            sudo sed -i '/^\[Container\]/a SecurityLabelDisable=true' "$f"
        done
        echo "✓ SELinux: removed :Z flags and set SecurityLabelDisable=true in container units"
    fi
    # Allow containers to bind to the ports they use (8080, 8443, 5433, 6379)
    for port in 8080 8443 5433 6379; do
        sudo semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || true
    done
    echo "✓ SELinux contexts and port labels set"
else
    echo "  SELinux is disabled, skipping"
fi

echo "Configuring firewalld..."
if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-port=8080/tcp
    sudo firewall-cmd --permanent --add-port=8443/tcp
    sudo firewall-cmd --reload
    echo "✓ firewalld: opened ports 8080/tcp and 8443/tcp"
else
    echo "  firewalld is not running, skipping"
fi

echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

# Stop services and reset any failure state (reverse dependency order)
for svc in quay.service quay-redis.service quay-postgres.service; do
    sudo systemctl stop "$svc" 2>/dev/null || true
    sudo systemctl reset-failed "$svc" 2>/dev/null || true
done
# Stop haproxy if it was previously deployed
sudo systemctl stop quay-haproxy.service 2>/dev/null || true
sleep 2

# Start postgres
echo "Starting quay-postgres service..."
sudo systemctl start quay-postgres.service
echo "Waiting for PostgreSQL to be ready..."
for i in $(seq 1 12); do
    if sudo podman exec quay-postgres pg_isready -U quay -d quay -q 2>/dev/null; then
        echo "✓ PostgreSQL is accepting connections (attempt $i)"
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "✗ ERROR: PostgreSQL did not become ready in time"
        sudo journalctl -u quay-postgres.service -n 20 --no-pager
        exit 1
    fi
    sleep 5
done

if systemctl is-active --quiet quay-postgres.service; then
    echo "✓ quay-postgres service is running"
else
    echo "✗ ERROR: quay-postgres service failed to start"
    sudo journalctl -u quay-postgres.service -n 20 --no-pager
    exit 1
fi

echo "Ensuring required PostgreSQL extensions..."
sudo podman exec quay-postgres psql -U quay -d quay -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' || {
    echo "✗ ERROR: Failed to create pg_trgm extension"
    exit 1
}
echo "✓ pg_trgm extension present"

# Start redis
echo "Starting quay-redis service..."
sudo systemctl start quay-redis.service
sleep 2

if systemctl is-active --quiet quay-redis.service; then
    echo "✓ quay-redis service is running"
else
    echo "✗ ERROR: quay-redis service failed to start"
    sudo journalctl -u quay-redis.service -n 20 --no-pager
    exit 1
fi

# Start quay
echo "Starting quay service..."
sudo systemctl start quay.service
echo "Waiting for Quay to initialize (this may take up to 3 min on first run)..."
QUAY_READY=false
for i in $(seq 1 18); do
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/v2/ 2>/dev/null || echo 000)
    if echo "$STATUS" | grep -qE '^(200|301|401|403)$'; then
        QUAY_READY=true
        echo "✓ Quay is responding (HTTP $STATUS) after $((i * 10))s"
        break
    fi
    if ! systemctl is-active --quiet quay.service; then
        echo "✗ ERROR: quay service stopped unexpectedly"
        sudo journalctl -u quay.service -n 30 --no-pager
        exit 1
    fi
    echo "  ...waiting (attempt $i/18, HTTP $STATUS)"
    sleep 10
done

if [ "$QUAY_READY" = "false" ]; then
    echo "✗ ERROR: Quay did not respond within 3 minutes"
    sudo journalctl -u quay.service -n 30 --no-pager
    exit 1
fi

# Create admin user if none exists yet
ADMIN_EXISTS=$(podman exec quay-postgres psql -U quay -d quay -tAc "SELECT COUNT(*) FROM \"user\" WHERE username='admin';" 2>/dev/null || echo 0)
if [ "$ADMIN_EXISTS" = "0" ] && [ -n "${QUAY_ADMIN_PASSWORD:-}" ]; then
    echo "Creating admin user..."
    HASH=$(podman exec "$(podman ps --filter 'ancestor=quay.io/projectquay/quay:latest' --format '{{.ID}}' | head -1)" \
        python3 -c "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" \
        "${QUAY_ADMIN_PASSWORD:-}" 2>/dev/null)
    podman exec quay-postgres psql -U quay -d quay -c "
        INSERT INTO \"user\" (uuid, username, email, password_hash, verified, organization, robot,
                             invoice_email, invalid_login_attempts, last_invalid_login,
                             removed_tag_expiration_s, enabled, creation_date)
        VALUES (gen_random_uuid(), 'admin', 'admin@arvhomelab.com', '\$HASH',
                true, false, false, false, 0, NOW(), 1209600, true, NOW())
        ON CONFLICT (username) DO NOTHING;
    " && echo "✓ Admin user created (username: admin)" || echo "⚠ Could not create admin user"
elif [ "$ADMIN_EXISTS" != "0" ]; then
    echo "✓ Admin user already exists, skipping creation"
else
    echo "⚠ Skipping admin user creation (set QUAY_ADMIN_PASSWORD env var to create on deploy)"
    echo "  Example: QUAY_ADMIN_PASSWORD='yourpassword' ./deploy-quay-local.sh"
fi

# Check if TLS certificates are installed in the Quay config dir
if [ -f "$CONFIG_DEST_DIR/ssl.cert" ] && [ -f "$CONFIG_DEST_DIR/ssl.key" ]; then
    echo "✓ TLS certificates found (ssl.cert + ssl.key) — Quay is serving HTTPS directly"
else
    echo "⚠ TLS certificates not yet installed"
    echo "  Re-run with --cert and --key to install certificates:"
    echo "    $0 --cert /path/to/ssl.cert --key /path/to/ssl.key"
    echo "  Quay will need to be restarted after certificates are installed."
fi

echo
echo "Testing Quay registry locally..."

echo "Testing Quay HTTP endpoint (direct, port 8080)..."
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${SERVER_IP}:8080/health" 2>/dev/null || echo '000')
if echo "$STATUS" | grep -qE "200"; then
    echo "✓ Quay HTTP endpoint is responding (HTTP $STATUS)"
else
    echo "✗ Quay HTTP endpoint is not responding (HTTP $STATUS)"
    echo "  Quay may still be initializing its database on first run."
fi

echo "Testing Quay v2 API (HTTP direct, port 8080)..."
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${SERVER_IP}:8080/v2/" 2>/dev/null || echo '000')
if echo "$STATUS" | grep -qE "200|401"; then
    echo "✓ Quay v2 API is responding (HTTP $STATUS)"
else
    echo "✗ Quay v2 API is not responding (HTTP $STATUS)"
fi

echo "Testing Quay HTTPS endpoint (direct, port 8443)..."
STATUS=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${SERVER_IP}:8443/health" 2>/dev/null || echo '000')
if echo "$STATUS" | grep -qE "200"; then
    echo "✓ Quay HTTPS endpoint is responding (HTTP $STATUS)"
else
    echo "✗ Quay HTTPS endpoint not responding (HTTP $STATUS) — ensure ssl.cert and ssl.key are installed"
fi

echo "Checking listening ports..."
sudo ss -tlnp | grep -E ':8080|:8443|:5433|:6379' | head -8 || true

echo
echo "=========================================="
echo "=== Deployment Complete ==="
echo "=========================================="
echo
echo "Useful commands:"
echo "  Check status:  systemctl status quay-postgres.service quay-redis.service quay.service"
echo "  View logs:     sudo journalctl -u quay.service -f"
echo "                 sudo journalctl -u quay-postgres.service -f"
echo "  Restart all:   sudo systemctl restart quay-postgres.service quay-redis.service quay.service"
echo "  Stop all:      sudo systemctl stop quay.service quay-redis.service quay-postgres.service"
echo "  Config dir:    $CONFIG_DEST_DIR/"
echo "  Storage dir:   $STORAGE_DIR/"
echo "  Postgres dir:  $POSTGRES_DIR/"
echo
echo "TLS certificate management:"
echo "  Install certs: $0 --cert /path/to/ssl.cert --key /path/to/ssl.key"
echo "  Cert dir:      $CONFIG_DEST_DIR/  (ssl.cert + ssl.key)"
echo
echo "Pull images:"
echo "  podman pull quay.arvhomelab.com/docker.io/library/nginx:latest"
echo
echo "Web UI: https://${SERVER_IP}:8443"
