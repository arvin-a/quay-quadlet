#!/bin/bash
# fix-quay-storage.sh
# Standalone script to detect and fix Quay storage ownership on any host.
# Run this on the machine that hosts the Quay container whenever you see
# 502 Bad Gateway errors on image push.
#
# Usage:
#   sudo ./fix-quay-storage.sh
#   sudo ./fix-quay-storage.sh --storage-dir /mirror/quay/storage
#   sudo ./fix-quay-storage.sh --container-name quay --storage-dir /mirror/quay/storage

set -euo pipefail

CONTAINER_NAME="quay"
STORAGE_DIR=""

usage() {
    echo "Usage: $0 [--container-name <name>] [--storage-dir <path>]"
    echo
    echo "Options:"
    echo "  --container-name <name>   Quay container name (default: quay)"
    echo "  --storage-dir <path>      Host path mounted as /datastorage in container"
    echo "                            (auto-detected from container inspect if omitted)"
    echo
    echo "Examples:"
    echo "  sudo $0"
    echo "  sudo $0 --storage-dir /mirror/quay/storage"
    echo "  sudo $0 --container-name quay --storage-dir /mirror/quay/storage"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container-name) CONTAINER_NAME="${2:-}"; shift 2 ;;
        --storage-dir)    STORAGE_DIR="${2:-}";    shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "✗ Unknown argument: $1"; usage; exit 1 ;;
    esac
done

echo "=== Quay Storage Ownership Fix ==="
echo

# ── Step 1: Verify the container is running ────────────────────────────────
echo "Checking container '${CONTAINER_NAME}'..."
if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    echo "✗ ERROR: Container '${CONTAINER_NAME}' is not running."
    echo "  Start it first: sudo systemctl start quay.service"
    exit 1
fi
echo "✓ Container '${CONTAINER_NAME}' is running"

# ── Step 2: Detect the Quay process UID from the running container ─────────
echo "Detecting Quay process UID inside container..."
QUAY_UID=$(podman exec "${CONTAINER_NAME}" id -u 2>/dev/null || echo "")
QUAY_GID=$(podman exec "${CONTAINER_NAME}" id -g 2>/dev/null || echo "0")
if [[ ! "$QUAY_UID" =~ ^[0-9]+$ ]]; then
    echo "✗ ERROR: Could not detect UID from container (got: '${QUAY_UID}')"
    exit 1
fi
echo "✓ Quay runs as UID=${QUAY_UID} GID=${QUAY_GID} inside the container"

# ── Step 3: Auto-detect storage host path if not provided ─────────────────
if [ -z "$STORAGE_DIR" ]; then
    echo "Auto-detecting storage host path from container mounts..."
    STORAGE_DIR=$(podman inspect "${CONTAINER_NAME}" \
        --format '{{range .Mounts}}{{if eq .Destination "/datastorage"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || echo "")
    if [ -z "$STORAGE_DIR" ]; then
        echo "✗ ERROR: Could not detect storage path from container inspect."
        echo "  Pass it explicitly: $0 --storage-dir /path/to/storage"
        exit 1
    fi
    echo "✓ Storage host path detected: ${STORAGE_DIR}"
else
    echo "  Using provided storage dir: ${STORAGE_DIR}"
fi

# ── Step 4: Ensure the registry subdirectory exists ────────────────────────
STORAGE_REGISTRY_DIR="${STORAGE_DIR}/registry"
if [ ! -d "$STORAGE_REGISTRY_DIR" ]; then
    echo "Creating missing registry subdirectory: ${STORAGE_REGISTRY_DIR}"
    mkdir -p "$STORAGE_REGISTRY_DIR"
    echo "✓ Created ${STORAGE_REGISTRY_DIR}"
fi

# ── Step 5: Apply ownership ────────────────────────────────────────────────
echo "Applying ownership ${QUAY_UID}:${QUAY_GID} to ${STORAGE_DIR}..."
chown -R "${QUAY_UID}:${QUAY_GID}" "$STORAGE_DIR"

ACTUAL_UID=$(stat -c '%u' "$STORAGE_DIR" 2>/dev/null)
if [ "$ACTUAL_UID" = "$QUAY_UID" ]; then
    echo "✓ Ownership set to UID ${QUAY_UID}"
else
    echo "⚠ chown did not take effect (actual UID: ${ACTUAL_UID})"
    echo "  Filesystem may not support chown to unmapped UIDs — setting 777:"
    chmod -R 777 "$STORAGE_DIR"
    echo "✓ Storage set to 777 (world-writable)"
fi

# ── Step 6: Re-apply SELinux context if active ─────────────────────────────
if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    echo "Re-applying SELinux context to ${STORAGE_DIR}..."
    if chcon -Rt container_file_t "$STORAGE_DIR" 2>/dev/null; then
        echo "✓ SELinux context set to container_file_t"
    else
        echo "  SELinux: filesystem does not support xattrs, skipping"
    fi
fi

# ── Step 7: Restart Quay ───────────────────────────────────────────────────
echo "Restarting Quay service..."
systemctl restart quay.service
echo "Waiting 20s for Quay to become ready..."
sleep 20

# ── Step 8: Verify writability from inside the container ──────────────────
echo "Verifying storage writability from inside the container..."
TEST_FILE="/datastorage/registry/.write-test"
if podman exec "${CONTAINER_NAME}" sh -c "touch ${TEST_FILE} && rm -f ${TEST_FILE}" 2>/dev/null; then
    echo "✓ Storage is writable — image pushes will work"
else
    echo "✗ Storage is still not writable."
    echo "  Container mounts:"
    podman inspect "${CONTAINER_NAME}" \
        --format '{{range .Mounts}}  {{.Type}}: {{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null || true
    echo "  Host storage permissions:"
    ls -lan "$STORAGE_DIR/"
    echo
    echo "  Possible causes:"
    echo "  1. Volume= line missing in the quay.container unit file"
    echo "  2. Storage path is on an NFS/network filesystem with squash_root"
    echo "  3. SELinux blocking access (check: ausearch -m avc -ts recent | grep quay)"
    exit 1
fi

echo
echo "=== Fix Complete ==="
echo "  Storage dir:  ${STORAGE_DIR}/"
echo "  Quay UID:     ${QUAY_UID}"
echo "  You can now push images:"
echo "  podman push <quay-hostname>:<port>/<org>/<repo>:tag"
