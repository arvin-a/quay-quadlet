#!/bin/bash

# Script to deploy Quay container registry on the local machine
# This script:
# 1. Deploys quay-postgres, quay-pgbouncer, quay-redis, quay .container files to /etc/containers/systemd/
# 2. Generates pgbouncer.ini and userlist.txt from DB_URI in config.yaml
# 3. Rewrites DB_URI in the deployed config.yaml to route through PgBouncer
# 4. Copies config.yaml to /home/mariam/app-data/quay/config
# 5. Optionally installs user-provided TLS certificates
# 6. Creates data, storage, postgres, pgbouncer, and redis dirs
# 7. Reloads systemd, starts services in order (postgres → pgbouncer → redis → quay), and tests them
#
# Connection flow: Quay --> PgBouncer :6432 (transaction pooling) --> PostgreSQL :5432
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
PGBOUNCER_DIR="${APP_DATA_DIR}/pgbouncer"
PGBOUNCER_PORT=6432
PGBOUNCER_CONTAINER_FILE="quay-pgbouncer.container"

# UID of the postgres process inside the postgres container image.
# Detected dynamically below for the quay image; this is the fallback.
QUAY_UID=1001
POSTGRES_UID=26

# Certificate paths (optional, provided via --cert / --key)
CERT_FILE=""
KEY_FILE=""

# Admin password reset (optional, provided via --reset-admin-password)
RESET_ADMIN_PASSWORD=""

usage() {
    echo "Usage: $0 [-h|--help] [--cert <cert-file>] [--key <key-file>] [--reset-admin-password <password>]"
    echo
    echo "Deploy Quay container registry with direct TLS (no HAProxy) on the local machine."
    echo
    echo "Options:"
    echo "  --cert <file>                   Path to the TLS certificate file (PEM) to install as ssl.cert"
    echo "  --key  <file>                   Path to the TLS private key file (PEM) to install as ssl.key"
    echo "  --reset-admin-password <pass>   Reset the 'admin' user password in the database"
    echo "  -h, --help                      Show this help message"
    echo
    echo "Architecture:"
    echo "  Client --HTTPS:8443--> Quay nginx (ssl.cert + ssl.key in config dir)"
    echo "  Client --HTTP:8080 --> Quay nginx (unencrypted, internal use only)"
    echo "  Quay --> PgBouncer :${PGBOUNCER_PORT} (connection pooler) --> PostgreSQL :5432"
    echo "  Redis is internal only"
    echo
    echo "Pre-deployment (edit configs/config.yaml first):"
    echo "  1. Generate secrets: openssl rand -hex 32"
    echo "  2. Set DATABASE_SECRET_KEY, SECRET_KEY, and DB_URI password"
    echo "  3. Update POSTGRESQL_PASSWORD in quay-postgres.container to match DB_URI"
    echo
    echo "Admin user creation (first deploy only):"
    echo "  QUAY_ADMIN_PASSWORD='yourpassword' $0 --cert /path/to/ssl.cert --key /path/to/ssl.key"
    echo "  (Skipped automatically if admin user already exists)"
    echo
    echo "Reset admin password (services must be running):"
    echo "  $0 --reset-admin-password 'newpassword'"
    echo
    echo "Login / push / pull (port :8443 required in every command):"
    echo "  podman login quay.arvhomelab.com:8443 -u admin"
    echo "  podman tag myimage:latest quay.arvhomelab.com:8443/<org>/<repo>:tag"
    echo "  podman push quay.arvhomelab.com:8443/<org>/<repo>:tag"
    echo "  podman pull quay.arvhomelab.com:8443/<org>/<repo>:tag"
    echo
    echo "Check service status:"
    echo "  systemctl status quay-postgres.service quay-pgbouncer.service quay-redis.service quay.service"
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
        --reset-admin-password)
            RESET_ADMIN_PASSWORD="${2:-}"
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

# ── Reset admin password (standalone operation, skips full deploy) ──────────
if [ -n "$RESET_ADMIN_PASSWORD" ]; then
    echo "=== Resetting Quay admin password ==="
    if ! systemctl is-active --quiet quay-postgres.service; then
        echo "✗ ERROR: quay-postgres.service is not running"
        exit 1
    fi
    QUAY_CONTAINER=$(sudo podman ps --filter 'ancestor=quay.io/projectquay/quay:latest' --format '{{.ID}}' | head -1)
    if [ -z "$QUAY_CONTAINER" ]; then
        echo "✗ ERROR: Quay container is not running"
        exit 1
    fi
    HASH=$(sudo podman exec "$QUAY_CONTAINER" \
        python3 -c "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" \
        "$RESET_ADMIN_PASSWORD" 2>/dev/null)
    if [ -z "$HASH" ]; then
        echo "✗ ERROR: Failed to generate bcrypt hash (is the quay container running?)"
        exit 1
    fi
    sudo podman exec quay-postgres psql -U quay -d quay -c \
        "UPDATE \"user\" SET password_hash='${HASH}', invalid_login_attempts=0 WHERE username='admin';" \
        && echo "✓ Admin password reset successfully (username: admin)" \
        || { echo "✗ ERROR: Database update failed"; exit 1; }
    echo "  Restart quay to ensure session caches are cleared:"
    echo "  sudo systemctl restart quay.service"
    exit 0
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

echo "Generating PgBouncer container unit file..."
sudo tee "/etc/containers/systemd/$PGBOUNCER_CONTAINER_FILE" > /dev/null <<EOF
[Unit]
Description=PgBouncer connection pooler for Quay
After=quay-postgres.service
Requires=quay-postgres.service

[Container]
Image=quay.io/crunchy-data/crunchy-pgbouncer:latest
ContainerName=quay-pgbouncer
Network=host
Volume=${PGBOUNCER_DIR}:/etc/pgbouncer:Z
Exec=pgbouncer /etc/pgbouncer/pgbouncer.ini

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target default.target
EOF
echo "✓ Generated /etc/containers/systemd/$PGBOUNCER_CONTAINER_FILE"

echo "Verifying storage Volume= mount in quay.container..."
INSTALLED_QUAY_UNIT="/etc/containers/systemd/$QUAY_CONTAINER_FILE"
if sudo grep -q "Volume=.*${STORAGE_DIR}.*:/datastorage" "$INSTALLED_QUAY_UNIT" 2>/dev/null; then
    echo "✓ Storage volume mount found in $QUAY_CONTAINER_FILE"
elif sudo grep -q "Volume=.*:/datastorage" "$INSTALLED_QUAY_UNIT" 2>/dev/null; then
    CURRENT_VOL=$(sudo grep "Volume=.*:/datastorage" "$INSTALLED_QUAY_UNIT" | head -1)
    echo "⚠ Storage volume mount exists but points to a different host path:"
    echo "  Found:    $CURRENT_VOL"
    echo "  Expected: Volume=${STORAGE_DIR}:/datastorage:Z"
    echo "  Updating to correct path..."
    sudo sed -i "s|Volume=.*:/datastorage.*|Volume=${STORAGE_DIR}:/datastorage:Z|" "$INSTALLED_QUAY_UNIT"
    echo "✓ Storage volume mount updated"
else
    echo "⚠ No datastorage Volume= line found — adding it now (blobs cannot be written without this)"
    sudo sed -i "/^\[Container\]/a Volume=${STORAGE_DIR}:/datastorage:Z" "$INSTALLED_QUAY_UNIT"
    echo "✓ Added: Volume=${STORAGE_DIR}:/datastorage:Z"
fi

echo "Creating directories..."
mkdir -p "$CONFIG_DEST_DIR"
mkdir -p "$STORAGE_DIR/registry"
mkdir -p "$POSTGRES_DIR"
mkdir -p "$PGBOUNCER_DIR"
echo "✓ Created $APP_DATA_DIR (including storage/registry, postgres, pgbouncer subdirectories)"

echo "Installing Quay configuration files..."
cp "$CONFIG_DIR/config.yaml" "$CONFIG_DEST_DIR/config.yaml"
echo "✓ Copied Quay config to $CONFIG_DEST_DIR"

# Extract DB credentials from config.yaml (DB_URI: postgresql://user:pass@host:port/db)
echo "Extracting database credentials from config.yaml..."
DB_URI_LINE=$(grep -E '^DB_URI:' "$CONFIG_DIR/config.yaml" | head -1)
DB_USER=$(echo "$DB_URI_LINE" | sed 's|.*://\([^:]*\):.*|\1|')
DB_PASS=$(echo "$DB_URI_LINE" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|')
DB_NAME=$(echo "$DB_URI_LINE" | sed 's|.*/\([^?]*\).*|\1|')
if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo "✗ ERROR: Could not parse DB_URI from configs/config.yaml"
    echo "  Expected format: DB_URI: postgresql://user:password@host:port/dbname"
    exit 1
fi
echo "✓ Parsed DB credentials (user: ${DB_USER}, db: ${DB_NAME})"

echo "Generating PgBouncer configuration files..."
# pgbouncer.ini
cat > "${PGBOUNCER_DIR}/pgbouncer.ini" <<EOF
[databases]
${DB_NAME} = host=127.0.0.1 port=5432 dbname=${DB_NAME}

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = ${PGBOUNCER_PORT}
auth_file = /etc/pgbouncer/userlist.txt
auth_type = scram-sha-256
pool_mode = transaction
max_client_conn = 500
default_pool_size = 40
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 5
server_reset_query = DISCARD ALL
server_check_delay = 30
server_idle_timeout = 600
client_idle_timeout = 300
log_connections = 0
log_disconnections = 0
log_pooler_errors = 1
stats_period = 60
EOF

# userlist.txt — PgBouncer needs the plain password for scram-sha-256 lookup
# We store it quoted as required by PgBouncer
cat > "${PGBOUNCER_DIR}/userlist.txt" <<EOF
"${DB_USER}" "${DB_PASS}"
EOF

chmod 600 "${PGBOUNCER_DIR}/userlist.txt"
chmod 644 "${PGBOUNCER_DIR}/pgbouncer.ini"
echo "✓ Generated ${PGBOUNCER_DIR}/pgbouncer.ini and userlist.txt"

# Rewrite DB_URI in the deployed config.yaml to route through PgBouncer
echo "Updating DB_URI in deployed config.yaml to use PgBouncer (port ${PGBOUNCER_PORT})..."
sed -i "s|postgresql://${DB_USER}:${DB_PASS}@[^/]*/${DB_NAME}|postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:${PGBOUNCER_PORT}/${DB_NAME}|" \
    "$CONFIG_DEST_DIR/config.yaml"
# Verify the rewrite took effect
if grep -q ":${PGBOUNCER_PORT}/" "$CONFIG_DEST_DIR/config.yaml"; then
    echo "✓ DB_URI now points to PgBouncer at 127.0.0.1:${PGBOUNCER_PORT}"
else
    echo "⚠ Could not auto-update DB_URI — update manually in $CONFIG_DEST_DIR/config.yaml:"
    echo "  Change the port in DB_URI from 5432 to ${PGBOUNCER_PORT}"
fi

if [ -n "$CERT_FILE" ]; then
    echo "Installing TLS certificates..."
    cp "$CERT_FILE" "$CONFIG_DEST_DIR/ssl.cert"
    cp "$KEY_FILE"  "$CONFIG_DEST_DIR/ssl.key"
    chmod 644 "$CONFIG_DEST_DIR/ssl.cert"
    chmod 644 "$CONFIG_DEST_DIR/ssl.key"
    echo "✓ Installed ssl.cert and ssl.key into $CONFIG_DEST_DIR"
fi

# Register the TLS cert with podman and the system trust store so that
# 'podman login' works without --tls-verify=false.
# Uses the cert already in the config dir (installed above, or from a previous run).
QUAY_CERT="${CONFIG_DEST_DIR}/ssl.cert"
if [ -f "$QUAY_CERT" ]; then
    echo "Registering Quay TLS cert with podman and system trust store..."
    _SH=$(grep -E '^SERVER_HOSTNAME:' "$CONFIG_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "quay.arvhomelab.com:8443")
    QUAY_HOSTNAME_ONLY=$(echo "$_SH" | cut -d: -f1)
    QUAY_PORT=$(echo "$_SH" | cut -s -d: -f2); QUAY_PORT="${QUAY_PORT:-443}"
    QUAY_CERTS_DIR="/etc/containers/certs.d/${QUAY_HOSTNAME_ONLY}:${QUAY_PORT}"
    sudo mkdir -p "$QUAY_CERTS_DIR"
    sudo cp "$QUAY_CERT" "${QUAY_CERTS_DIR}/ca.crt"
    echo "✓ Cert registered at ${QUAY_CERTS_DIR}/ca.crt (podman will trust it)"
    sudo cp "$QUAY_CERT" /etc/pki/ca-trust/source/anchors/quay-${QUAY_HOSTNAME_ONLY}.crt
    sudo update-ca-trust extract
    echo "✓ Cert added to system trust store (curl, browsers, oc will trust it)"
else
    echo "⚠ No ssl.cert found — skipping cert trust registration"
    echo "  Re-run with --cert and --key to install certificates"
fi

echo "Detecting Quay container UID from image..."
DETECTED_QUAY_UID=$(sudo podman image inspect quay.io/projectquay/quay:latest \
    --format '{{.Config.User}}' 2>/dev/null | tr -d '"' | cut -d: -f1)
if [[ "$DETECTED_QUAY_UID" =~ ^[0-9]+$ ]]; then
    QUAY_UID="$DETECTED_QUAY_UID"
    echo "✓ Quay image UID detected: ${QUAY_UID}"
else
    echo "  Could not detect UID from image metadata (got: '${DETECTED_QUAY_UID}'), using default: ${QUAY_UID}"
fi

echo "Detecting Postgres container UID from image..."
QUAY_POSTGRES_IMAGE=$(grep -E '^Image=' "/etc/containers/systemd/$POSTGRES_CONTAINER_FILE" 2>/dev/null | head -1 | cut -d= -f2)
DETECTED_PG_UID=$(sudo podman image inspect "${QUAY_POSTGRES_IMAGE:-quay.io/sclorg/postgresql-15-c9s}" \
    --format '{{.Config.User}}' 2>/dev/null | tr -d '"' | cut -d: -f1)
if [[ "$DETECTED_PG_UID" =~ ^[0-9]+$ ]]; then
    POSTGRES_UID="$DETECTED_PG_UID"
    echo "✓ Postgres image UID detected: ${POSTGRES_UID}"
else
    echo "  Could not detect UID from postgres image, using default: ${POSTGRES_UID}"
fi

echo "Setting permissions..."
sudo chown -R mariam:mariam "$APP_DATA_DIR"
chmod 644 "$CONFIG_DEST_DIR/config.yaml"
echo "✓ Base permissions set"

echo "Fixing storage directory ownership (UID ${QUAY_UID} = quay user inside container)..."
sudo chown -R "${QUAY_UID}:${QUAY_UID}" "$STORAGE_DIR"
ACTUAL_UID=$(stat -c '%u' "$STORAGE_DIR" 2>/dev/null)
if [ "$ACTUAL_UID" = "$QUAY_UID" ]; then
    echo "✓ Storage directory ownership set to UID ${QUAY_UID}"
else
    echo "⚠ chown to UID ${QUAY_UID} did not take effect (actual UID: ${ACTUAL_UID})"
    echo "  Filesystem may not support chown to unmapped UIDs — setting 777 as fallback:"
    sudo chmod -R 777 "$STORAGE_DIR"
    echo "✓ Storage set to world-writable (777)"
fi

echo "Fixing postgres data directory ownership (UID ${POSTGRES_UID} = postgres user inside container)..."
sudo chown -R "${POSTGRES_UID}:${POSTGRES_UID}" "$POSTGRES_DIR"
ACTUAL_PG_UID=$(stat -c '%u' "$POSTGRES_DIR" 2>/dev/null)
if [ "$ACTUAL_PG_UID" = "$POSTGRES_UID" ]; then
    echo "✓ Postgres directory ownership set to UID ${POSTGRES_UID}"
else
    echo "⚠ chown to UID ${POSTGRES_UID} did not take effect — setting 777 as fallback:"
    sudo chmod -R 777 "$POSTGRES_DIR"
    echo "✓ Postgres dir set to world-writable (777)"
fi

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
                 "/etc/containers/systemd/$REDIS_CONTAINER_FILE" \
                 "/etc/containers/systemd/$PGBOUNCER_CONTAINER_FILE"; do
            sudo sed -i 's/:Z\b//g' "$f"
            sudo sed -i '/^\[Container\]/a SecurityLabelDisable=true' "$f"
        done
        echo "✓ SELinux: removed :Z flags and set SecurityLabelDisable=true in container units"
    fi
    # Allow containers to bind to the ports they use
    for port in 8080 8443 5432 6379 ${PGBOUNCER_PORT}; do
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
for svc in quay.service quay-redis.service quay-pgbouncer.service quay-postgres.service; do
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
    if sudo podman exec quay-postgres pg_isready -U quay -d quay -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
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

echo "Starting quay-pgbouncer service..."
sudo systemctl start quay-pgbouncer.service
echo "Waiting for PgBouncer to be ready..."
for i in $(seq 1 12); do
    if sudo podman exec quay-pgbouncer psql \
        "postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:${PGBOUNCER_PORT}/${DB_NAME}" \
        -c "SELECT 1" -q 2>/dev/null | grep -q 1; then
        echo "✓ PgBouncer is accepting connections (attempt $i)"
        break
    fi
    # Fallback: check the port is open
    if nc -z 127.0.0.1 "${PGBOUNCER_PORT}" 2>/dev/null; then
        echo "✓ PgBouncer port ${PGBOUNCER_PORT} is open (attempt $i)"
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "✗ ERROR: PgBouncer did not become ready in time"
        sudo journalctl -u quay-pgbouncer.service -n 20 --no-pager
        exit 1
    fi
    sleep 5
done

if systemctl is-active --quiet quay-pgbouncer.service; then
    echo "✓ quay-pgbouncer service is running"
else
    echo "✗ ERROR: quay-pgbouncer service failed to start"
    sudo journalctl -u quay-pgbouncer.service -n 20 --no-pager
    exit 1
fi

echo "Ensuring required PostgreSQL extensions..."
sudo podman exec quay-postgres psql -U quay -d quay -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' 2>/dev/null || \
sudo podman exec --user root quay-postgres psql -U postgres -d quay -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' || {
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

echo "Verifying storage is writable from inside the Quay container..."
STORAGE_TEST_FILE="/datastorage/registry/.write-test"
if sudo podman exec quay sh -c "touch ${STORAGE_TEST_FILE} && rm -f ${STORAGE_TEST_FILE}" 2>/dev/null; then
    echo "✓ Storage is writable — blob uploads will work"
else
    echo "⚠ Storage not writable — detecting actual Quay process UID and fixing ownership..."
    RUNTIME_QUAY_UID=$(sudo podman exec quay id -u 2>/dev/null || echo "")
    if [[ "$RUNTIME_QUAY_UID" =~ ^[0-9]+$ ]]; then
        echo "  Quay process runs as UID ${RUNTIME_QUAY_UID} inside the container"
        sudo chown -R "${RUNTIME_QUAY_UID}:${RUNTIME_QUAY_UID}" "$STORAGE_DIR"
        ACTUAL_UID=$(stat -c '%u' "$STORAGE_DIR" 2>/dev/null)
        if [ "$ACTUAL_UID" = "$RUNTIME_QUAY_UID" ]; then
            echo "✓ Storage ownership corrected to UID ${RUNTIME_QUAY_UID}"
        else
            echo "  chown not supported on this filesystem — setting 777 as fallback:"
            sudo chmod -R 777 "$STORAGE_DIR"
            echo "✓ Storage set to 777 (world-writable)"
        fi
    else
        echo "  Could not detect runtime UID — setting 777 as fallback:"
        sudo chmod -R 777 "$STORAGE_DIR"
        echo "✓ Storage set to 777 (world-writable)"
    fi
    echo "  Restarting Quay to pick up ownership change..."
    sudo systemctl restart quay.service
    sleep 15
    if sudo podman exec quay sh -c "touch ${STORAGE_TEST_FILE} && rm -f ${STORAGE_TEST_FILE}" 2>/dev/null; then
        echo "✓ Storage is now writable — blob uploads will work"
    else
        echo "✗ ERROR: Storage still not writable after fix."
        echo "  Mount state:"
        sudo podman inspect quay --format \
            '{{range .Mounts}}  {{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null || true
        echo "  Host storage permissions:"
        ls -lan "$STORAGE_DIR/"
        exit 1
    fi
fi

# Create admin user if none exists yet
ADMIN_EXISTS=$(sudo podman exec quay-postgres psql -U quay -d quay -tAc "SELECT COUNT(*) FROM \"user\" WHERE username='admin';" 2>/dev/null || echo 0)
if [ "$ADMIN_EXISTS" = "0" ] && [ -n "${QUAY_ADMIN_PASSWORD:-}" ]; then
    echo "Creating admin user..."
    HASH=$(sudo podman exec "$(sudo podman ps --filter 'ancestor=quay.io/projectquay/quay:latest' --format '{{.ID}}' | head -1)" \
        python3 -c "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" \
        "${QUAY_ADMIN_PASSWORD:-}" 2>/dev/null)
    sudo podman exec quay-postgres psql -U quay -d quay -c "
        INSERT INTO \"user\" (uuid, username, email, password_hash, verified, organization, robot,
                             invoice_email, invalid_login_attempts, last_invalid_login,
                             removed_tag_expiration_s, enabled, creation_date)
        VALUES (gen_random_uuid(), 'admin', 'admin@mariamhomelab.com', '${HASH}',
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
sudo ss -tlnp | grep -E ":8080|:8443|:5432|:${PGBOUNCER_PORT}|:6379" | head -10 || true

echo
echo "=========================================="
echo "=== Deployment Complete ==="
echo "=========================================="
echo
echo "Useful commands:"
echo "  Check status:  systemctl status quay-postgres.service quay-pgbouncer.service quay-redis.service quay.service"
echo "  View logs:     sudo journalctl -u quay.service -f"
echo "                 sudo journalctl -u quay-pgbouncer.service -f"
echo "                 sudo journalctl -u quay-postgres.service -f"
echo "  Restart all:   sudo systemctl restart quay-postgres.service quay-pgbouncer.service quay-redis.service quay.service"
echo "  Stop all:      sudo systemctl stop quay.service quay-redis.service quay-pgbouncer.service quay-postgres.service"
echo "  PgBouncer stats: sudo podman exec quay-pgbouncer psql -p ${PGBOUNCER_PORT} -U ${DB_USER:-quay} pgbouncer -c 'SHOW POOLS;'"
echo "  Config dir:    $CONFIG_DEST_DIR/"
echo "  Storage dir:   $STORAGE_DIR/"
echo "  Postgres dir:  $POSTGRES_DIR/"
echo "  PgBouncer dir: $PGBOUNCER_DIR/"
echo
echo "TLS certificate management:"
echo "  Install certs: $0 --cert /path/to/ssl.cert --key /path/to/ssl.key"
echo "  Cert dir:      $CONFIG_DEST_DIR/  (ssl.cert + ssl.key)"
echo
echo "Pull images:"
echo "  podman pull quay.arvhomelab.com/docker.io/library/nginx:latest"
echo
echo "Web UI: https://${SERVER_IP}:8443"
