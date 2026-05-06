#!/bin/bash

# Script to deploy Quay container registry to remote servers
# This script:
# 1. Deploys quay-postgres, quay-redis, quay .container files to /etc/containers/systemd/
# 2. Copies config.yaml to /home/mariam/app-data/quay/config
# 3. Copies Let's Encrypt scripts and Cloudflare credentials
# 4. Creates data, storage, postgres, and redis dirs
# 5. Reloads systemd, starts the services in order, and tests them
#
# TLS is terminated directly by Quay (ssl.cert + ssl.key in config dir).
# Run setup_letsencrypt.sh after first deploy to obtain and install certificates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Server configurations (format: server_name=hostname)
declare -A SERVERS
SERVERS[infra-lb1]="infra-lb1.arvhomelab.com"

# Source files
POSTGRES_CONTAINER_FILE="quay-postgres.container"
REDIS_CONTAINER_FILE="quay-redis.container"
QUAY_CONTAINER_FILE="quay.container"
CONFIG_DIR="configs"
LE_SETUP_SCRIPT="setup_letsencrypt.sh"
LE_RENEWAL_SCRIPT="setup_renewal.sh"
CF_INI_FILE="cloudflare.ini"

# Remote user
REMOTE_USER="arvin"

# Remote paths
APP_DATA_DIR="/home/mariam/app-data/quay"
CONFIG_DEST_DIR="${APP_DATA_DIR}/config"
STORAGE_DIR="${APP_DATA_DIR}/storage"
POSTGRES_DIR="${APP_DATA_DIR}/postgres"

deploy_to_server() {
    local server=$1
    local hostname="${SERVERS[$server]}"

    echo "=========================================="
    echo "Deploying to $server ($hostname)"
    echo "=========================================="
    echo

    deploy_remote "$server" "$hostname"
}

deploy_remote() {
    local server=$1
    local hostname=$2

    local REMOTE_DIR="/tmp/quay-deploy-$$"
    local REMOTE_HOST="${REMOTE_USER}@${hostname}"

    local SSH_OPTS=(
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -F "/dev/null"
    )

    echo "Deploying to remote host: $REMOTE_HOST"
    echo

    echo "Checking source files..."
    for f in "$POSTGRES_CONTAINER_FILE" "$REDIS_CONTAINER_FILE" "$QUAY_CONTAINER_FILE" \
              "$LE_SETUP_SCRIPT" "$LE_RENEWAL_SCRIPT" "$CF_INI_FILE"; do
        if [ ! -f "$f" ]; then
            echo "✗ ERROR: Source file '$f' not found in $SCRIPT_DIR"
            return 1
        fi
    done
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "✗ ERROR: Config directory '$CONFIG_DIR' not found in $SCRIPT_DIR"
        return 1
    fi
    echo "✓ All source files found"
    echo

    echo "Creating temporary directory on remote host..."
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p $REMOTE_DIR" || {
        echo "✗ ERROR: Failed to connect to $REMOTE_HOST"
        echo "  Make sure SSH key authentication is set up"
        return 1
    }

    echo "Copying files to remote host..."
    scp "${SSH_OPTS[@]}" \
        "$POSTGRES_CONTAINER_FILE" "$REDIS_CONTAINER_FILE" "$QUAY_CONTAINER_FILE" \
        "$REMOTE_HOST:$REMOTE_DIR/" || return 1
    scp "${SSH_OPTS[@]}" -r "$CONFIG_DIR" "$REMOTE_HOST:$REMOTE_DIR/" || return 1
    scp "${SSH_OPTS[@]}" "$LE_SETUP_SCRIPT" "$LE_RENEWAL_SCRIPT" "$CF_INI_FILE" "$REMOTE_HOST:$REMOTE_DIR/" || return 1
    echo "✓ Files copied"
    echo

    echo "Executing deployment on remote host..."
    ssh "${SSH_OPTS[@]}" -t "$REMOTE_HOST" "bash -s" <<REMOTE_SCRIPT || return 1
set -euo pipefail
cd $REMOTE_DIR

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

echo "Installing Let's Encrypt scripts and Cloudflare config..."
cp "$LE_SETUP_SCRIPT" "$LE_RENEWAL_SCRIPT" "$CF_INI_FILE" "$APP_DATA_DIR/"
chmod +x "$APP_DATA_DIR/$LE_SETUP_SCRIPT" "$APP_DATA_DIR/$LE_RENEWAL_SCRIPT"
chmod 600 "$APP_DATA_DIR/$CF_INI_FILE"
echo "✓ Copied Let's Encrypt scripts and Cloudflare config to $APP_DATA_DIR"

echo "Setting permissions..."
sudo chown -R mariam:mariam "$APP_DATA_DIR"
chmod 644 "$CONFIG_DEST_DIR/config.yaml"
echo "✓ Permissions set"

echo "Fixing postgres data directory ownership (UID 999 = postgres inside container)..."
sudo chown -R 999:999 "$POSTGRES_DIR"
echo "✓ Postgres data directory ownership set"

echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

# Stop services and reset any failure state (reverse dependency order)
for svc in quay.service quay-redis.service quay-postgres.service; do
    sudo systemctl stop "\$svc" 2>/dev/null || true
    sudo systemctl reset-failed "\$svc" 2>/dev/null || true
done
# Stop haproxy if it was previously deployed
sudo systemctl stop quay-haproxy.service 2>/dev/null || true
sleep 2

# Start postgres
echo "Starting quay-postgres service..."
sudo systemctl start quay-postgres.service
echo "Waiting for PostgreSQL to be ready..."
for i in \$(seq 1 12); do
    if sudo podman exec quay-postgres pg_isready -U quay -d quay -q 2>/dev/null; then
        echo "✓ PostgreSQL is accepting connections (attempt \$i)"
        break
    fi
    if [ "\$i" -eq 12 ]; then
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
for i in \$(seq 1 18); do
    STATUS=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/v2/ 2>/dev/null || echo 000)
    if echo "\$STATUS" | grep -qE '^(200|401|403)$'; then
        QUAY_READY=true
        echo "✓ Quay is responding (HTTP \$STATUS) after \$((i * 10))s"
        break
    fi
    if ! systemctl is-active --quiet quay.service; then
        echo "✗ ERROR: quay service stopped unexpectedly"
        sudo journalctl -u quay.service -n 30 --no-pager
        exit 1
    fi
    echo "  ...waiting (attempt \$i/18, HTTP \$STATUS)"
    sleep 10
done

if [ "\$QUAY_READY" = "false" ]; then
    echo "✗ ERROR: Quay did not respond within 3 minutes"
    sudo journalctl -u quay.service -n 30 --no-pager
    exit 1
fi

# Create admin user if none exists yet
ADMIN_EXISTS=\$(podman exec quay-postgres psql -U quay -d quay -tAc "SELECT COUNT(*) FROM \"user\" WHERE username='admin';" 2>/dev/null || echo 0)
if [ "\$ADMIN_EXISTS" = "0" ] && [ -n "${QUAY_ADMIN_PASSWORD:-}" ]; then
    echo "Creating admin user..."
    HASH=\$(podman exec \$(podman ps --filter 'ancestor=quay.io/projectquay/quay:latest' --format '{{.ID}}' | head -1) \
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
elif [ "\$ADMIN_EXISTS" != "0" ]; then
    echo "✓ Admin user already exists, skipping creation"
else
    echo "⚠ Skipping admin user creation (set QUAY_ADMIN_PASSWORD env var to create on deploy)"
    echo "  Example: QUAY_ADMIN_PASSWORD='yourpassword' ./deploy-quay-remote.sh"
fi

# Check if TLS certificates are installed in the Quay config dir
if [ -f "$CONFIG_DEST_DIR/ssl.cert" ] && [ -f "$CONFIG_DEST_DIR/ssl.key" ]; then
    echo "✓ TLS certificates found (ssl.cert + ssl.key) — Quay is serving HTTPS directly"
else
    echo "⚠ TLS certificates not yet installed"
    echo "  Run setup_letsencrypt.sh on the server to obtain and install certificates:"
    echo "    cd $APP_DATA_DIR && ./setup_letsencrypt.sh"
    echo "  Quay will restart automatically after certificates are installed."
fi
REMOTE_SCRIPT

    echo
    echo "Testing Quay registry on remote host..."
    test_quay_remote "$REMOTE_HOST" "${SSH_OPTS[@]}"

    echo "Cleaning up temporary files..."
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "rm -rf $REMOTE_DIR" || true

    echo "✓ Remote deployment to $server complete"
    echo
}

test_quay_remote() {
    local remote_host=$1
    shift
    local ssh_opts=("$@")

    echo "Testing Quay HTTP endpoint (direct, port 8080)..."
    local status
    status=$(ssh "${ssh_opts[@]}" "$remote_host" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://192.168.4.19:8080/health' 2>/dev/null || echo '000'")
    if echo "$status" | grep -qE "200"; then
        echo "✓ Quay HTTP endpoint is responding (HTTP $status)"
    else
        echo "✗ Quay HTTP endpoint is not responding (HTTP $status)"
        echo "  Quay may still be initializing its database on first run."
    fi

    echo "Testing Quay v2 API (HTTP direct, port 8080)..."
    status=$(ssh "${ssh_opts[@]}" "$remote_host" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://192.168.4.19:8080/v2/' 2>/dev/null || echo '000'")
    if echo "$status" | grep -qE "200|401"; then
        echo "✓ Quay v2 API is responding (HTTP $status)"
    else
        echo "✗ Quay v2 API is not responding (HTTP $status)"
    fi

    echo "Testing Quay HTTPS endpoint (direct, port 8443)..."
    status=$(ssh "${ssh_opts[@]}" "$remote_host" \
        "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 'https://192.168.4.19:8443/health' 2>/dev/null || echo '000'")
    if echo "$status" | grep -qE "200"; then
        echo "✓ Quay HTTPS endpoint is responding (HTTP $status)"
    else
        echo "✗ Quay HTTPS endpoint not responding (HTTP $status) — run setup_letsencrypt.sh first"
    fi

    echo "Checking listening ports..."
    ssh "${ssh_opts[@]}" "$remote_host" "sudo ss -tlnp | grep -E ':8080|:8443|:5433|:6379' | head -8" || true
}

usage() {
    echo "Usage: $0 [server_name|all]"
    echo
    echo "Deploy Quay container registry with direct TLS (no HAProxy)."
    echo
    echo "Architecture:"
    echo "  Client --HTTPS:8443--> Quay nginx (ssl.cert + ssl.key in config dir)"
    echo "  Client --HTTP:8080 --> Quay nginx (unencrypted, internal use only)"
    echo "  PostgreSQL and Redis are internal only"
    echo
    echo "Arguments:"
    echo "  server_name  Deploy to specific server (e.g., infra-lb1)"
    echo "  all          Deploy to all configured servers (default)"
    echo
    echo "Configured servers:"
    for server in "${!SERVERS[@]}"; do
        echo "  - $server (${SERVERS[$server]})"
    done
    echo
    echo "Pre-deployment (edit configs/config.yaml first):"
    echo "  1. Generate secrets: openssl rand -hex 32"
    echo "  2. Set DATABASE_SECRET_KEY, SECRET_KEY, and DB_URI password"
    echo "  3. Update POSTGRES_PASSWORD in quay-postgres.container to match DB_URI"
    echo
    echo "Admin user creation (first deploy only):"
    echo "  QUAY_ADMIN_PASSWORD='yourpassword' $0"
    echo "  (Skipped automatically if admin user already exists)"
    echo
    echo "Post-deployment (if first time):"
    echo "  1. Update cloudflare.ini with your API token on the server"
    echo "  2. Run: cd /home/mariam/app-data/quay && ./setup_letsencrypt.sh"
    echo "     (installs ssl.cert + ssl.key into config dir and restarts quay)"
    echo "  3. Run: cd /home/mariam/app-data/quay && ./setup_renewal.sh"
    echo "     (sets up automatic renewal via certbot deploy hook)"
    echo
    echo "Pull images through the registry:"
    echo "  podman pull quay.arvhomelab.com/docker.io/library/nginx:latest"
    echo
    echo "Check service status:"
    echo "  systemctl status quay-postgres.service quay-redis.service quay.service"
}

# Main execution
echo "=== Deploying Quay container registry ==="
echo

TARGET="${1:-all}"

if [ "$TARGET" == "-h" ] || [ "$TARGET" == "--help" ]; then
    usage
    exit 0
fi

if [ "$TARGET" == "all" ]; then
    for server in "${!SERVERS[@]}"; do
        deploy_to_server "$server"
    done
else
    if [ -z "${SERVERS[$TARGET]+x}" ]; then
        echo "✗ ERROR: Unknown server '$TARGET'"
        echo
        usage
        exit 1
    fi
    deploy_to_server "$TARGET"
fi

echo "=========================================="
echo "=== All Deployments Complete ==="
echo "=========================================="
echo
echo "Useful commands (run on remote server):"
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
echo "  Setup certs:   cd $APP_DATA_DIR && ./setup_letsencrypt.sh"
echo "  Setup renewal: cd $APP_DATA_DIR && ./setup_renewal.sh"
echo
echo "Pull images:"
echo "  podman pull quay.arvhomelab.com/docker.io/library/nginx:latest"
echo
echo "Web UI: https://quay.arvhomelab.com"
