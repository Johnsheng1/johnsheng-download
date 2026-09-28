#!/usr/bin/env bash
#
# RelayPanel relay-node installer.
#
# Supports:
#   - Alpine Linux / OpenRC
#   - Linux distributions using systemd
#
# Usage:
#   bash relay-node-install-alpine.sh -t <NODE_TOKEN> -u <PANEL_URL>
#
# On a bare Alpine system, bootstrap the shell and downloader first if needed:
#   apk add --no-cache bash curl ca-certificates
#
# Options:
#   -t, --token         Node token (required, from the panel UI)
#   -u, --url           Panel URL (required), e.g. http://panel-ip:18888
#   -s, --service-name  Service name (default: relay-node)
#   -p, --proxy         Download proxy, e.g. socks5://127.0.0.1:10808
#   --version X.Y.Z     Install a specific node version
#
# Environment:
#   RELAY_PROXY           Same as -p
#   RELAY_NODE_BASE_URL   Custom binary mirror base URL
#   SKIP_CHECKSUM=1       Skip checksum verification (not recommended)
#
# The binary is downloaded to a temporary file, checksum/ELF-validated, then
# atomically swapped in after the current service has been stopped.
#
set -euo pipefail

# Do not inherit a deleted working directory when invoked through process
# substitution or from a temporary directory.
cd / 2>/dev/null || true

SCRIPT_VERSION="1.2.5"
REPO="MoeShinX/relay-panel"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { printf '%b[INFO]%b  %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b  %s\n' "$YELLOW" "$NC" "$*" >&2; }
fail() { printf '%b[FAIL]%b  %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

NODE_TOKEN=""
PANEL_URL=""
SERVICE_NAME="relay-node"
PROXY="${RELAY_PROXY:-}"
TARGET_VERSION=""

usage() {
    cat <<'EOF'
Usage: bash relay-node-install-alpine.sh -t <token> -u <panel-url> [options]

Options:
  -t, --token         Node token from the panel UI (required)
  -u, --url           Panel URL, e.g. http://panel-ip:18888 (required)
  -s, --service-name  Service name (default: relay-node)
  -p, --proxy         Download proxy, e.g. socks5://127.0.0.1:10808
  --version X.Y.Z     Install a specific node version
  -h, --help          Show this help

Environment:
  RELAY_PROXY           Same as -p
  RELAY_NODE_BASE_URL   Custom mirror for relay-node-linux-{arch}
  SKIP_CHECKSUM=1       Skip SHA256 verification (not recommended)
EOF
}

require_option_value() {
    [ "$#" -ge 2 ] || fail "Option $1 requires a value."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--token)
            require_option_value "$@"
            NODE_TOKEN="$2"
            shift 2
            ;;
        -u|--url)
            require_option_value "$@"
            PANEL_URL="$2"
            shift 2
            ;;
        -s|--service-name)
            require_option_value "$@"
            SERVICE_NAME="$2"
            shift 2
            ;;
        -p|--proxy)
            require_option_value "$@"
            PROXY="$2"
            shift 2
            ;;
        --version)
            require_option_value "$@"
            TARGET_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

[ -n "$NODE_TOKEN" ] || fail "Missing required option: -t/--token."
[ -n "$PANEL_URL" ] || fail "Missing required option: -u/--url."

case "$SERVICE_NAME" in
    ""|*[!A-Za-z0-9_.@-]*)
        fail "Invalid service name: $SERVICE_NAME. Use only letters, digits, ., _, @ and -."
        ;;
esac

if [ "$(uname -s)" != "Linux" ]; then
    fail "This installer only runs on Linux. Current OS: $(uname -s)"
fi

if [ "$(id -u)" -ne 0 ]; then
    fail "Please run as root (use sudo)."
fi

# Alpine's base image may not contain curl, CA certificates, or iproute2.
# Install only missing packages. systemd hosts are left untouched.
IS_ALPINE=0
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=1
fi

if [ "$IS_ALPINE" -eq 1 ]; then
    command -v apk >/dev/null 2>&1 || fail "Alpine detected but apk is unavailable."
    ALPINE_PACKAGES=()
    command -v curl >/dev/null 2>&1 || ALPINE_PACKAGES+=(curl)
    [ -s /etc/ssl/certs/ca-certificates.crt ] || ALPINE_PACKAGES+=(ca-certificates)
    # OUTBOUND_INTERFACE uses the ip command in relay-node.
    command -v ip >/dev/null 2>&1 || ALPINE_PACKAGES+=(iproute2)
    if [ "${#ALPINE_PACKAGES[@]}" -gt 0 ]; then
        info "Installing Alpine dependencies: ${ALPINE_PACKAGES[*]}"
        apk add --no-cache "${ALPINE_PACKAGES[@]}"
    fi
fi

command -v curl >/dev/null 2>&1 || fail "curl is required. Install curl and try again."
command -v awk >/dev/null 2>&1 || fail "awk is required."
command -v grep >/dev/null 2>&1 || fail "grep is required."
command -v sed >/dev/null 2>&1 || fail "sed is required."
command -v od >/dev/null 2>&1 || fail "od is required for ELF validation."

BASH_PATH="$(command -v bash || true)"
[ -n "$BASH_PATH" ] || fail "bash is required. Install bash and try again."

# Prefer a running systemd instance. Alpine normally takes the OpenRC branch.
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
elif command -v systemctl >/dev/null 2>&1; then
    # This keeps systemd support for installation environments where systemd is
    # installed but /run/systemd/system is not mounted yet.
    INIT_SYSTEM="systemd"
else
    fail "Neither systemd nor OpenRC was detected."
fi
info "Detected init system: $INIT_SYSTEM"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $ARCH_RAW. Only amd64 and arm64 are supported." ;;
esac
info "Detected architecture: $ARCH ($ARCH_RAW)"

INSTALL_DIR="/opt/${SERVICE_NAME}"
BINARY="${INSTALL_DIR}/relay-node"
TMP_BINARY="${BINARY}.tmp"
if [ "$INIT_SYSTEM" = "systemd" ]; then
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
else
    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
fi

PROXY_ARGS=()
if [ -n "$PROXY" ]; then
    PROXY_ARGS+=(--proxy "$PROXY")
fi

resolve_node_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases?per_page=30"
    local raw

    # BusyBox sort does not reliably implement GNU sort -V. Prefix each
    # semantic-version component with fixed-width numeric fields instead.
    raw="$(curl -fsSL --connect-timeout 10 --max-time 20 \
        "${PROXY_ARGS[@]}" \
        -H 'User-Agent: relay-node-install' "$api_url" 2>/dev/null \
        | grep -oE '"tag_name": "node-v[0-9]+\.[0-9]+\.[0-9]+[^"]*"' \
        | sed -E 's/"tag_name": "node-v//; s/"$//' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
        | awk -F. '{ p=$3; sub(/-.*/, "", p); printf "%012d%012d%012d %s\\n", $1+0, $2+0, p+0, $0 }' \
        | sort -r \
        | head -n1 \
        | cut -d' ' -f2- || true)"
    printf '%s\n' "$raw"
}

if [ -z "$TARGET_VERSION" ]; then
    info "Querying GitHub for the latest node-v* release ..."
    LATEST_NODE="$(resolve_node_version)"
    if [ -n "$LATEST_NODE" ]; then
        TARGET_VERSION="$LATEST_NODE"
        info "Latest node release: $TARGET_VERSION"
    else
        TARGET_VERSION="$SCRIPT_VERSION"
        warn "Could not query GitHub; falling back to bundled version $SCRIPT_VERSION. Use --version X.Y.Z to pin a version."
    fi
else
    info "Installing node version: $TARGET_VERSION (pinned)"
fi

case "$TARGET_VERSION" in
    *[!0-9A-Za-z._-]*) fail "Invalid node version: $TARGET_VERSION" ;;
esac

ALREADY_AT_VERSION=0
if [ -x "$BINARY" ]; then
    INSTALLED_VERSION="$("$BINARY" --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n1 || true)"
    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        info "Already at node version $TARGET_VERSION; skipping binary download."
        ALREADY_AT_VERSION=1
    elif [ -n "$INSTALLED_VERSION" ]; then
        info "Installed version: $INSTALLED_VERSION -> upgrading to $TARGET_VERSION"
    fi
fi

if [ "$ALREADY_AT_VERSION" != "1" ]; then
    ASSET_NAME="relay-node-linux-${ARCH}"

    url_tag_prefix() {
        local v="$1"
        local base major minor patch rest
        base="${v%%-*}"
        major="${base%%.*}"
        rest="${base#*.}"
        minor="${rest%%.*}"
        patch="${rest#*.}"
        major="${major:-0}"
        minor="${minor:-0}"
        patch="${patch:-0}"

        if [ "$major" -lt 1 ] \
            || { [ "$major" -eq 1 ] && [ "$minor" -lt 1 ]; } \
            || { [ "$major" -eq 1 ] && [ "$minor" -eq 1 ] && [ "$patch" -lt 1 ]; }; then
            printf 'v\n'
        else
            printf 'node-v\n'
        fi
    }

    if [ -n "${RELAY_NODE_BASE_URL:-}" ]; then
        DOWNLOAD_URL="${RELAY_NODE_BASE_URL%/}/${ASSET_NAME}"
        info "Using custom mirror: ${RELAY_NODE_BASE_URL}"
    else
        TAG_PREFIX="$(url_tag_prefix "$TARGET_VERSION")"
        DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG_PREFIX}${TARGET_VERSION}/${ASSET_NAME}"
    fi

    CURL_OPTS=(-fL --progress-bar --connect-timeout 10 --max-time 120 \
        --retry 3 --retry-delay 2 --retry-connrefused)
    info "Downloading relay-node v${TARGET_VERSION} (${ARCH}) ..."
    info "URL: $DOWNLOAD_URL"
    mkdir -p "$INSTALL_DIR"
    rm -f "$TMP_BINARY"

    if ! curl "${CURL_OPTS[@]}" "${PROXY_ARGS[@]}" "$DOWNLOAD_URL" -o "$TMP_BINARY"; then
        rm -f "$TMP_BINARY"
        fail "Download failed. Check the release asset, proxy, or mirror. Existing binary was not changed."
    fi

    if [ "${SKIP_CHECKSUM:-0}" != "1" ]; then
        CHECKSUM_URL="${DOWNLOAD_URL}.sha256"
        TMP_CHECKSUM="${TMP_BINARY}.sha256"
        rm -f "$TMP_CHECKSUM"

        if curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 \
            --retry-delay 2 --retry-connrefused "${PROXY_ARGS[@]}" \
            "$CHECKSUM_URL" -o "$TMP_CHECKSUM"; then
            EXPECTED="$(awk 'NF { print $1; exit }' "$TMP_CHECKSUM" | tr -d '[:space:]')"
            if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
                rm -f "$TMP_BINARY" "$TMP_CHECKSUM"
                fail "Checksum file is empty or malformed: $CHECKSUM_URL"
            fi

            ACTUAL=""
            if command -v sha256sum >/dev/null 2>&1; then
                ACTUAL="$(sha256sum "$TMP_BINARY" | awk '{ print $1 }')"
            elif command -v shasum >/dev/null 2>&1; then
                ACTUAL="$(shasum -a 256 "$TMP_BINARY" | awk '{ print $1 }')"
            elif command -v sha256 >/dev/null 2>&1; then
                ACTUAL="$(sha256 "$TMP_BINARY" | awk '{ print $1 }')"
            else
                rm -f "$TMP_BINARY" "$TMP_CHECKSUM"
                fail "No SHA256 utility found. Install sha256sum/shasum, or use SKIP_CHECKSUM=1."
            fi

            EXPECTED_LC="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
            ACTUAL_LC="$(printf '%s' "$ACTUAL" | tr '[:upper:]' '[:lower:]')"
            if [ "$ACTUAL_LC" != "$EXPECTED_LC" ]; then
                rm -f "$TMP_BINARY" "$TMP_CHECKSUM"
                fail "Checksum verification failed. Existing binary was not changed."
            fi
            info "Checksum verified (sha256 OK)."
            rm -f "$TMP_CHECKSUM"
        elif [ -z "${RELAY_NODE_BASE_URL:-}" ]; then
            rm -f "$TMP_BINARY" "$TMP_CHECKSUM"
            fail "Checksum file not found: $CHECKSUM_URL. Use SKIP_CHECKSUM=1 only if you accept the risk."
        else
            warn "Mirror does not provide $CHECKSUM_URL; continuing without checksum verification."
        fi
    else
        warn "SKIP_CHECKSUM=1 set; checksum verification is disabled."
    fi

    if command -v xxd >/dev/null 2>&1; then
        ELF_MAGIC="$(head -c 4 "$TMP_BINARY" 2>/dev/null | xxd -p -c 4 2>/dev/null || true)"
    else
        ELF_MAGIC=""
    fi
    if [ "$ELF_MAGIC" != "7f454c46" ]; then
        ELF_MAGIC="$(od -A n -t x1 -N 4 "$TMP_BINARY" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [ "$ELF_MAGIC" != "7f454c46" ]; then
        FILE_DESC="not an ELF binary"
        if command -v file >/dev/null 2>&1; then
            FILE_DESC="$(file -b "$TMP_BINARY" 2>/dev/null || printf 'not an ELF binary')"
        fi
        rm -f "$TMP_BINARY"
        fail "Downloaded file is invalid: $FILE_DESC. Existing binary was not changed."
    fi

    FILE_SIZE="$(stat -c '%s' "$TMP_BINARY" 2>/dev/null || stat -f '%z' "$TMP_BINARY" 2>/dev/null || printf '0')"
    if [ "$FILE_SIZE" -lt 100000 ]; then
        rm -f "$TMP_BINARY"
        fail "Downloaded file is too small (${FILE_SIZE} bytes). Existing binary was not changed."
    fi

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if [ -f "$SERVICE_FILE" ] && systemctl is-active --quiet "$SERVICE_NAME"; then
            info "Stopping existing $SERVICE_NAME service for binary swap ..."
            systemctl stop "$SERVICE_NAME" || warn "systemctl stop returned non-zero; continuing."
        fi
    else
        if [ -f "$SERVICE_FILE" ] && rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
            info "Stopping existing $SERVICE_NAME service for binary swap ..."
            rc-service "$SERVICE_NAME" stop || warn "rc-service stop returned non-zero; continuing."
        fi
    fi

    mv -f "$TMP_BINARY" "$BINARY"
    chmod 755 "$BINARY"
    info "Binary installed: $BINARY ($((FILE_SIZE / 1024 / 1024)) MB, ELF $ARCH)"
fi

START_SH="${INSTALL_DIR}/start.sh"
info "Writing start script: $START_SH"
cat > "$START_SH" <<'STARTEOF'
#!/bin/sh
set -eu
cd "__INSTALL_DIR__"
export PANEL_URL="__PANEL_URL__"
export NODE_TOKEN="__NODE_TOKEN__"
export POLL_INTERVAL="${POLL_INTERVAL:-10}"
export RUST_LOG="${RUST_LOG:-info}"

if [ -f "__INSTALL_DIR__/relay-node.env" ]; then
    set -a
    . "__INSTALL_DIR__/relay-node.env"
    set +a
fi

exec ./relay-node
STARTEOF

# Escape values used as sed replacement text. This keeps tokens containing '&',
# '|', or backslashes from corrupting the generated launcher.
sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}
PANEL_URL_ESC="$(sed_escape "$PANEL_URL")"
NODE_TOKEN_ESC="$(sed_escape "$NODE_TOKEN")"
INSTALL_DIR_ESC="$(sed_escape "$INSTALL_DIR")"
sed -i "s|__PANEL_URL__|${PANEL_URL_ESC}|g" "$START_SH"
sed -i "s|__NODE_TOKEN__|${NODE_TOKEN_ESC}|g" "$START_SH"
sed -i "s|__INSTALL_DIR__|${INSTALL_DIR_ESC}|g" "$START_SH"
chmod 700 "$START_SH"

if grep -q '/dev/fd' "$START_SH" 2>/dev/null; then
    fail "Generated start.sh contains /dev/fd; refusing to continue."
fi

ENV_FILE="${INSTALL_DIR}/relay-node.env"
if [ ! -f "$ENV_FILE" ]; then
    info "Writing example environment file: $ENV_FILE"
    cat > "$ENV_FILE" <<'ENVEOF'
# Optional relay-node environment. Uncomment and edit values as needed.
# Variables are exported to relay-node by start.sh.

# Inbound listen addresses. Empty disables that address family.
# LISTEN_IPV4=0.0.0.0
# LISTEN_IPV6=::

# IPv4 outbound selection for multi-NIC servers.
# OUTBOUND_INTERFACE=eth0
# OUTBOUND_BIND_IPV4=192.0.2.10

# Public-IP detection overrides. Each endpoint must return a bare IP and be
# family-specific.
# PUBLIC_IPV4_CHECK_URL=https://ipv4.icanhazip.com
# PUBLIC_IPV6_CHECK_URL=https://ipv6.icanhazip.com

# Graceful shutdown drain timeout in seconds. Default 5, maximum 60.
# SHUTDOWN_DRAIN_SECS=5
ENVEOF
    chmod 600 "$ENV_FILE"
fi

if [ "$INIT_SYSTEM" = "systemd" ]; then
    info "Writing systemd unit: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=RelayNode forwarding service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BASH_PATH} ${START_SH}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

    info "Enabling and starting ${SERVICE_NAME} ..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
else
    info "Writing OpenRC service: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<SVCEOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="RelayNode forwarding service"
command="${START_SH}"
command_user="root:root"
pidfile="/run/${SERVICE_NAME}.pid"

# Keep the same behavior as systemd Restart=always / RestartSec=3.
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
respawn_period=0
rc_ulimit="-n 65536"
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.err"

depend() {
    need net
    after firewall
}
SVCEOF
    chmod 755 "$SERVICE_FILE"

    info "Enabling and starting ${SERVICE_NAME} ..."
    rc-update add "$SERVICE_NAME" default >/dev/null
    if ! rc-service "$SERVICE_NAME" restart; then
        rc-service "$SERVICE_NAME" start
    fi
fi

sleep 2
if [ "$INIT_SYSTEM" = "systemd" ]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "Service ${SERVICE_NAME} is running."
    else
        warn "Service ${SERVICE_NAME} failed to start. Recent logs:"
        journalctl -u "$SERVICE_NAME" --no-pager -n 50 2>/dev/null || true
    fi
else
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        info "Service ${SERVICE_NAME} is running."
    else
        warn "Service ${SERVICE_NAME} failed to start. Check:"
        warn "  tail -n 50 /var/log/${SERVICE_NAME}.err"
        warn "  tail -n 50 /var/log/${SERVICE_NAME}.log"
    fi
fi

printf '\n'
info "=========================================="
info " relay-node installed successfully!"
info "=========================================="
printf '\n'
printf '  Service:   %s\n' "$SERVICE_NAME"
printf '  Binary:    %s\n' "$BINARY"
printf '  Version:   v%s\n' "$TARGET_VERSION"
printf '  Panel:     %s\n' "$PANEL_URL"
printf '\n'
if [ "$INIT_SYSTEM" = "systemd" ]; then
    printf '  Logs:      journalctl -u %s -f\n' "$SERVICE_NAME"
    printf '  Status:    systemctl status %s\n' "$SERVICE_NAME"
    printf '  Stop:      systemctl stop %s\n' "$SERVICE_NAME"
    printf '  Restart:   systemctl restart %s\n' "$SERVICE_NAME"
    printf '  Uninstall: systemctl disable --now %s; rm -f %s; rm -rf %s\n' "$SERVICE_NAME" "$SERVICE_FILE" "$INSTALL_DIR"
else
    printf '  Logs:      tail -f /var/log/%s.log /var/log/%s.err\n' "$SERVICE_NAME" "$SERVICE_NAME"
    printf '  Status:    rc-service %s status\n' "$SERVICE_NAME"
    printf '  Stop:      rc-service %s stop\n' "$SERVICE_NAME"
    printf '  Restart:   rc-service %s restart\n' "$SERVICE_NAME"
    printf '  Uninstall: rc-update del %s default; rc-service %s stop; rm -f %s; rm -rf %s\n' "$SERVICE_NAME" "$SERVICE_NAME" "$SERVICE_FILE" "$INSTALL_DIR"
fi
printf '  Upgrade:   re-run this installer with the same -t/-u flags\n\n'
