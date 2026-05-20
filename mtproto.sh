#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
BIN_PATH="/usr/local/bin/mtg"
CONF_DIR="/etc/mtproto"
CONFIG_FILE="$CONF_DIR/config.toml"
SERVICE_NAME="mtproto"
DEFAULT_DOMAIN="google.com"

require_root() {
	[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
}

cleanup() {
	rm -rf /tmp/mtg
}
trap cleanup EXIT

# ===== INSTALL DEPS =====
install_deps() {
    install_pkg() {
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y "$@"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$@"
        elif command -v yum &>/dev/null; then
            yum install -y "$@"
        fi
    }

    command -v curl &>/dev/null || install_pkg curl
    command -v git &>/dev/null || install_pkg git
    command -v go &>/dev/null || install_pkg golang
}

# ===== BUILD MTG =====
build_mtg() {
	if [ -f "$BIN_PATH" ]; then return; fi

	echo "[*] Building mtg..."

	pushd /tmp >/dev/null || return 1
	rm -rf mtg
	git clone https://github.com/9seconds/mtg.git
	cd mtg

	go build -o mtg

	mv mtg "$BIN_PATH"
	chmod +x "$BIN_PATH"
	popd >/dev/null || return 1
}

# ===== GENERATE SECRET =====
generate_secret() {
    read -p "Fake TLS domain [$DEFAULT_DOMAIN]: " DOMAIN
    DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

    SECRET=$("$BIN_PATH" generate-secret --hex "$DOMAIN")
    SECRET=$(echo "$SECRET" | tr -d '\n\r ')

    if [ -z "$SECRET" ]; then
        echo "Secret generation failed"
        exit 1
    fi

    echo "$SECRET"
}

# ===== CONFIG =====
create_config() {
    SECRET=$(generate_secret)

    read -p "Ports (comma, default 443): " PORTS
    PORTS=${PORTS:-443}

    > "$CONFIG_FILE"

    for p in $(echo "$PORTS" | tr ',' ' '); do
        echo "bind-to = \"0.0.0.0:$p\"" >> "$CONFIG_FILE"
    done

    echo "secret = \"$SECRET\"" >> "$CONFIG_FILE"
}

# ===== GET IP =====
get_ip() {
    IP=$(curl -s -4 --max-time 5 https://api.ipify.org || true)
    [ -z "$IP" ] && IP=$(hostname -I | awk '{print $1}')
    echo "$IP"
}

# ===== SERVICE =====
create_service() {

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=MTProto Proxy (mtg)
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH run $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME
}

# ===== HEALTH =====
health_check() {
    sleep 2
    if ! systemctl is-active --quiet $SERVICE_NAME; then
        echo "Service failed:"
        journalctl -u $SERVICE_NAME -n 30 --no-pager
        exit 1
    fi
}

# ===== SHOW INFO =====
show_info() {
    IP=$(get_ip)

    SECRET=$(grep secret "$CONFIG_FILE" | cut -d '"' -f2)
	PORTS=$(grep '^bind-to' "$CONFIG_FILE" | cut -d ':' -f2 | tr -d '"' | tr ',' ' ')

	echo ""
	echo "IP: $IP"
	echo "Ports: $PORTS"
	echo "Secret: $SECRET"
	echo ""

	for p in $PORTS; do
		echo "tg://proxy?server=$IP&port=$p&secret=$SECRET"
	done

    echo ""
    echo "Logs: journalctl -u $SERVICE_NAME -f"
}

# ===== REMOVE =====
remove_all() {
    systemctl stop $SERVICE_NAME &>/dev/null
    systemctl disable $SERVICE_NAME &>/dev/null
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    systemctl daemon-reload
    rm -rf "$CONF_DIR"
    rm -f "$BIN_PATH"
    echo "Removed"
}

# ===== MAIN =====
main() {
	require_root
	mkdir -p "$CONF_DIR"

	while true; do
    echo ""
    echo "1) Install / Reinstall"
    echo "2) Show info"
    echo "3) Logs"
    echo "4) Restart"
    echo "5) Remove"
    echo "0) Exit"
    read -p "Select: " opt

    case $opt in
        1)
            install_deps
            build_mtg
            create_config
            create_service
            health_check
            show_info
            ;;
        2) show_info ;;
        3) journalctl -u $SERVICE_NAME -f ;;
        4) systemctl restart $SERVICE_NAME ;;
        5) remove_all ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done
}

main "$@"