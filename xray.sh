#!/usr/bin/env bash
set -euo pipefail

### ===== CONFIG =====
XRAY_VERSION="v26.5.9"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
LOG_DIR="/var/log/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"

PORT=3443
SNI_HOST="ads.x5.ru"
FP="firefox"
### ==================

require_root() {
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
}

detect_arch() {
case "$(uname -m)" in
x86_64) echo "64" ;;
aarch64|arm64) echo "arm64" ;;
armv7l) echo "arm32-v7a" ;;
i386) echo "32" ;;
*) echo "Unsupported arch"; exit 1 ;;
esac
}

clean_all() {
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
rm -f "$SERVICE_FILE"
	systemctl daemon-reload

rm -f "$XRAY_BIN"
rm -rf "$XRAY_DIR" "$LOG_DIR"
}

install_deps() {
apt update
apt install -y wget unzip python3 python3-cryptography jq
}

install_xray() {
	local ARCH TMP XRAY_BINARY
	ARCH=$(detect_arch)
	TMP=$(mktemp -d)
	trap "rm -rf '$TMP'" RETURN

	wget -q \
		"https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip" \
		-O "$TMP/xray.zip" || { echo "Download failed"; exit 1; }

	unzip -q "$TMP/xray.zip" -d "$TMP"

	XRAY_BINARY=$(find "$TMP" -maxdepth 1 -type f -name 'xray*' | head -1)
	if [ -z "$XRAY_BINARY" ]; then
		echo "Xray binary not found in archive"
		exit 1
	fi

	install -m 755 "$XRAY_BINARY" "$XRAY_BIN"
	rm -rf "$TMP"
}

generate_crypto() {
python3 <<'PY'
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
import base64, uuid, secrets, json

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

priv = x25519.X25519PrivateKey.generate()
priv_raw = priv.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
pub_raw = priv.public_key().public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)

print(json.dumps({
    "privateKey": b64url(priv_raw),
    "pbk": b64url(pub_raw),
    "uuid": str(uuid.uuid4()),
    "sid": secrets.token_hex(4),
    "path": "/"
}))
PY
}

write_config() {
mkdir -p "$XRAY_DIR" "$LOG_DIR"

DATA=$(generate_crypto)

PRIVATE_KEY=$(echo "$DATA" | jq -r .privateKey)
PBK=$(echo "$DATA" | jq -r .pbk)
UUID=$(echo "$DATA" | jq -r .uuid)
SID=$(echo "$DATA" | jq -r .sid)
PATH_HTTP=$(echo "$DATA" | jq -r .path)

cat > "$XRAY_DIR/config.json" <<EOF
{
"log": {
"loglevel": "warning",
"access": "$LOG_DIR/access.log",
"error": "$LOG_DIR/error.log"
},
"inbounds": [
{
"port": $PORT,
"protocol": "vless",
"settings": {
"decryption": "none",
"clients": [
{ "id": "$UUID" }
]
},
"streamSettings": {
"network": "xhttp",
"security": "reality",
"xhttpSettings": {
"path": "$PATH_HTTP",
"mode": "auto"
},
"realitySettings": {
"dest": "$SNI_HOST:443",
"serverNames": ["$SNI_HOST"],
"privateKey": "$PRIVATE_KEY",
"shortIds": ["$SID"]
}
}
}
],
"outbounds": [
{ "protocol": "freedom" }
]
}
EOF
}

write_service() {
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Core Service
After=network.target

[Service]
ExecStart=$XRAY_BIN run -config $XRAY_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
}

print_report() {
	local uuid="$1" private_key="$2" pbk="$3" sid="$4"
	echo
	echo "=========== REALITY REPORT ==========="
	echo "Xray version : $XRAY_VERSION"
	echo "UUID : $uuid"
	echo "PrivateKey : $private_key"
	echo "PublicKey : $pbk"
	echo "SID : $sid"
	echo "Path : /"
	echo
	echo "VLESS URL (replace IP):"
	echo
	echo "vless://$uuid@IP:$PORT?type=xhttp&security=reality&encryption=none&path=%2F&pbk=$pbk&sni=$SNI_HOST&sid=$sid&fp=$FP"
	echo "====================================="
}

main() {
require_root
clean_all
install_deps
install_xray
write_config
write_service

	if ! "$XRAY_BIN" -test -config "$XRAY_DIR/config.json"; then
		echo "Config test failed"
		exit 1
	fi

	systemctl enable xray
	systemctl start xray
	systemctl --no-pager status xray | head -n 10

	print_report "$UUID" "$PRIVATE_KEY" "$PBK" "$SID"
}

main
