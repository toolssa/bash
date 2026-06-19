#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/openlibrecommunity/olcrtc"
BRANCH="${BRANCH:-master}"

PREFIX="/opt/olcrtc"
SRC_DIR="${PREFIX}/src"
DATA_DIR="${PREFIX}/data"
BIN="/usr/local/bin/olcrtc"

CONF_DIR="/etc/olcrtc"
SERVER_CONF="${CONF_DIR}/server.yaml"
CLIENT_CONF="${CONF_DIR}/client.example.yaml"
KEY_FILE="${CONF_DIR}/olcrtc.key"

SERVICE="/etc/systemd/system/olcrtc.service"

DEFAULT_ROOM_BASE="${DEFAULT_ROOM_BASE:-https://meet.handyweb.org}"
ROOM_URL="${1:-${ROOM_URL:-}}"

TRANSPORT="${TRANSPORT:-datachannel}"
DNS="${DNS:-8.8.8.8:53}"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-8808}"
DEBUG="${DEBUG:-false}"

GO_VERSION="${GO_VERSION:-1.24.5}"
GO_ROOT="/opt/go-${GO_VERSION}"
GO_LINK="/opt/go"
GO_BIN="${GO_ROOT}/bin/go"

SKIP_JITSI_CHECK="${SKIP_JITSI_CHECK:-false}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[+] $*"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

normalize_room_url() {
  if [[ -z "${ROOM_URL}" ]]; then
    read -rp "Jitsi room URL [auto ${DEFAULT_ROOM_BASE}/olcrtc-XXXX]: " ROOM_URL || true
  fi

  if [[ -z "${ROOM_URL}" ]]; then
    ROOM_URL="${DEFAULT_ROOM_BASE}/olcrtc-$(openssl rand -hex 16)"
  fi

  ROOM_URL="${ROOM_URL%/}"

  [[ "${ROOM_URL}" =~ ^https://[^/]+/.+ ]] || \
    die "ROOM_URL must look like: https://meet.example.org/room-name"
}

validate_jitsi_host() {
  if [[ "${SKIP_JITSI_CHECK}" == "true" ]]; then
    log "Skipping Jitsi host check (SKIP_JITSI_CHECK=true)"
    return
  fi

  local host
  host="$(echo "${ROOM_URL}" | awk -F/ '{print $1"//"$3}')"

  log "Validating Jitsi host: ${host}"

  if ! curl -fsSL --max-time 8 "${host}/config.js" \
    | grep -qE 'hosts:|config\.hosts|bosh:|websocket|external_api'; then
    log "WARNING: Host ${host} does not look like Jitsi, continuing anyway"
  fi
}

install_deps() {
  log "Installing base packages"
  apt-get update
  apt-get install -y git curl ca-certificates build-essential openssl tar qrencode
}

install_go() {
  if [[ -x "${GO_BIN}" ]] && "${GO_BIN}" version | grep -q "go${GO_VERSION}"; then
    log "Go ${GO_VERSION} already installed at ${GO_ROOT}"
    return
  fi

  local arch
  arch="$(detect_arch)"

  if [[ -d "${GO_ROOT}" ]]; then
    log "Removing existing installation at ${GO_ROOT}"
    rm -rf "${GO_ROOT}"
  fi

  log "Installing Go ${GO_VERSION} for linux-${arch} into ${GO_ROOT}"

  curl -fL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz

  mkdir -p /opt
  rm -rf /opt/go
  tar -C /opt -xzf /tmp/go.tgz
  mv /opt/go "${GO_ROOT}"
  rm -f /tmp/go.tgz

  ln -sfn "${GO_ROOT}" "${GO_LINK}"
  "${GO_BIN}" version
}

install_mage() {
  log "Installing mage"
  export PATH="${GO_ROOT}/bin:/root/go/bin:${PATH}"
  go install github.com/magefile/mage@latest
}

build_olcrtc() {
  log "Fetching source"
  rm -rf "${SRC_DIR}"
  mkdir -p "${PREFIX}"
  git clone --depth 1 --branch "${BRANCH}" "${REPO}" "${SRC_DIR}"

  log "Building olcrtc"
  export PATH="${GO_ROOT}/bin:/root/go/bin:${PATH}"

  (
    cd "${SRC_DIR}"
    /root/go/bin/mage build
  )

  local built
  built="$(find "${SRC_DIR}/build" -type f -name 'olcrtc-linux-*' -perm -111 | head -n1 || true)"

  [[ -n "${built}" ]] || die "Built binary not found in ${SRC_DIR}/build"

  install -m 0755 "${built}" "${BIN}"

  if ! "${BIN}" --help >/dev/null 2>&1; then
    log "WARNING: Binary ${BIN} --help check failed, continuing; systemd will verify runtime"
  fi
}

write_configs() {
  log "Writing configs"

  mkdir -p "${CONF_DIR}" "${DATA_DIR}"
  chmod 700 "${CONF_DIR}"

  if [[ ! -f "${KEY_FILE}" ]]; then
    openssl rand -hex 32 > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
  fi

  if [[ -f "${SERVER_CONF}" ]]; then
    local old_room
    old_room="$(grep 'id:' "${SERVER_CONF}" | head -n1 | awk '{print $2}' | tr -d '"' || true)"

    if [[ -n "${old_room}" && "${old_room}" != "${ROOM_URL}" ]]; then
      log "WARNING: existing config has room ${old_room}, replacing with ${ROOM_URL} (key unchanged)"
    fi
  fi

  cat > "${SERVER_CONF}" <<EOF
mode: srv

auth:
  provider: jitsi

room:
  id: "${ROOM_URL}"

crypto:
  key_file: "./olcrtc.key"

net:
  transport: ${TRANSPORT}
  dns: "${DNS}"

liveness:
  interval: 10s
  timeout: 5s
  failures: 3

lifecycle:
  max_session_duration: 6h

data: "${DATA_DIR}"
debug: ${DEBUG}
EOF

  local key
  key="$(cat "${KEY_FILE}")"

  cat > "${CLIENT_CONF}" <<EOF
mode: cnc

auth:
  provider: jitsi

room:
  id: "${ROOM_URL}"

crypto:
  key: "${key}"

net:
  transport: ${TRANSPORT}
  dns: "${DNS}"

socks:
  host: "${SOCKS_HOST}"
  port: ${SOCKS_PORT}

liveness:
  interval: 10s
  timeout: 5s
  failures: 3

lifecycle:
  max_session_duration: 6h

data: "data"
debug: false
EOF

  chmod 600 "${SERVER_CONF}" "${CLIENT_CONF}"
}

write_systemd() {
  log "Writing systemd unit"

  cat > "${SERVICE}" <<EOF
[Unit]
Description=olcRTC server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN} ${SERVER_CONF}
Restart=always
RestartSec=5
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable olcrtc >/dev/null

  log "Starting olcrtc"
  systemctl restart olcrtc

  sleep 2

  if ! systemctl is-active --quiet olcrtc; then
    journalctl -u olcrtc -n 80 --no-pager || true
    die "olcrtc failed to start"
  fi
}

export_qr() {
  [[ -f "${CLIENT_CONF}" ]] || die "Client config not found: ${CLIENT_CONF}. Run installation first."

  command -v qrencode >/dev/null 2>&1 || apt-get install -y qrencode

  local out_dir
  out_dir="$(pwd)"

  cp "${CLIENT_CONF}" "${out_dir}/client.yaml"
  qrencode -t PNG -r "${out_dir}/client.yaml" -o "${out_dir}/client.png"

  log "Saved: ${out_dir}/client.yaml"
  log "Saved: ${out_dir}/client.png"

  echo
  echo "WARNING: client.yaml contains the secret key."
  echo "After transferring to your phone, delete both files:"
  echo "  rm -f ${out_dir}/client.yaml ${out_dir}/client.png"
}

print_result() {
  echo
  echo "===== SERVER ====="
  echo "Room:     ${ROOM_URL}"
  echo "Config:   ${SERVER_CONF}"
  echo "Service:  systemctl status olcrtc"
  echo "Logs:     journalctl -u olcrtc -f"
  echo
  echo "===== CLIENT CONFIG (contains secret key — copy and delete from server) ====="
  cat "${CLIENT_CONF}"
  echo "============================================================================="
  echo
  echo "After copying the client config, remove it from the server:"
  echo "  rm -f ${CLIENT_CONF}"
  echo
  echo "Or generate QR code for mobile:"
  echo "  $0 --export-qr"
  echo
  echo "Client check after start:"
  echo "  curl --socks5-hostname ${SOCKS_HOST}:${SOCKS_PORT} https://icanhazip.com"
}

main() {
  require_root

  if [[ "${1:-}" == "--export-qr" ]]; then
    export_qr
    exit 0
  fi

  install_deps
  normalize_room_url
  validate_jitsi_host
  install_go
  install_mage
  build_olcrtc
  write_configs
  write_systemd
  print_result
}

main "$@"