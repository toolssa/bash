#!/usr/bin/env bash
set -uo pipefail
trap 'echo -e "\n${RED:-}ERROR on line ${LINENO}${NC:-}"' ERR

# =========================
# COLORS
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# =========================
# UTILS
# =========================
ensure_curl() {
	if ! command -v curl >/dev/null 2>&1; then
		apt update && apt install -y curl
	fi
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

systemd_unit_exists() {
	systemctl list-unit-files 2>/dev/null | grep -q "^$1\.service"
}

trim_spaces() {
	local s="$1"
	s="${s//$'\r'/}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

confirm() {
	local prompt="$1"
	local yn
	echo -en "${YELLOW}$prompt [y/N]: ${NC}"
	read -r yn
	[[ "$yn" =~ ^[Yy]$ ]]
}

pause() {
	echo ""
	echo -en "${DIM}Press Enter to continue...${NC}"
	read -r
}

menu_header() {
	local title="$1"
	local len=${#title}
	local line
	line=$(printf '=%.0s' $(seq 1 $((len + 4))))
	echo ""
	echo -e "${YELLOW}${line}${NC}"
	echo -e "${YELLOW}  ${title}${NC}"
	echo -e "${YELLOW}${line}${NC}"
}

print_menu_item() {
	local num="$1" desc="$2" color="${3:-$WHITE}"
	printf "${color}[%s]${NC} %s\n" "$num" "$desc"
}

require_root() {
	if [ "${EUID:-$(id -u)}" -ne 0 ]; then
		echo "Run as root" >&2
		exit 1
	fi
}

# =========================
# HYSTERIA 2
# =========================

apps_install_hysteria2() {
	local CONFIRM
	ensure_curl
	echo -e "${YELLOW}WARNING:${NC} this will execute the official Hysteria 2 install script"
	read -rp "Continue? [y/N]: " CONFIRM
	[[ "$CONFIRM" =~ ^[Yy]$ ]] || return

	if bash <(curl -fsSL https://get.hy2.sh/); then
		echo -e "${GREEN}OK:${NC} Hysteria 2 installed or upgraded"
	else
		echo -e "${RED}ERROR:${NC} failed to install or upgrade Hysteria 2"
	fi
}

apps_install_hysteria2_version() {
	local CONFIRM VERSION
	ensure_curl
	read -rp "Version (e.g. v2.8.1): " VERSION
	VERSION="$(trim_spaces "$VERSION")"

	if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]]; then
		echo -e "${RED}ERROR:${NC} invalid version"
		return
	fi

	echo -e "${YELLOW}WARNING:${NC} this will execute the official Hysteria 2 install script"
	read -rp "Continue? [y/N]: " CONFIRM
	[[ "$CONFIRM" =~ ^[Yy]$ ]] || return

	if bash <(curl -fsSL https://get.hy2.sh/) --version "$VERSION"; then
		echo -e "${GREEN}OK:${NC} Hysteria 2 installed or upgraded to $VERSION"
	else
		echo -e "${RED}ERROR:${NC} failed to install or upgrade Hysteria 2 to $VERSION"
	fi
}

apps_remove_hysteria2() {
	local CONFIRM
	ensure_curl
	echo -e "${YELLOW}WARNING:${NC} this will remove Hysteria 2 and its service"
	read -rp "Continue? [y/N]: " CONFIRM
	[[ "$CONFIRM" =~ ^[Yy]$ ]] || return

	if bash <(curl -fsSL https://get.hy2.sh/) --remove; then
		echo -e "${GREEN}OK:${NC} Hysteria 2 removed"
	else
		echo -e "${RED}ERROR:${NC} failed to remove Hysteria 2"
	fi
}

apps_hysteria2_menu() {
	require_root
	while true; do
		clear
		menu_header "Hysteria 2"
		echo ""
		print_menu_item "1" "Install / Upgrade (latest)" "$GREEN"
		print_menu_item "2" "Install / Upgrade specific version" "$GREEN"
		echo ""
		print_menu_item "3" "Status" "$CYAN"
		print_menu_item "4" "Restart" "$YELLOW"
		print_menu_item "5" "View Logs" "$CYAN"
		print_menu_item "6" "Show Config" "$CYAN"
		echo ""
		print_menu_item "7" "Uninstall" "$RED"
		echo ""
		print_menu_item "0" "Back" "$GRAY"
		echo ""

		read -rp "Select: " c

		case "$c" in
			1) apps_install_hysteria2; pause ;;
			2) apps_install_hysteria2_version; pause ;;
			3) systemctl status hysteria-server.service; pause ;;
			4) systemctl restart hysteria-server.service && echo -e "${GREEN}OK:${NC} Hysteria 2 restarted" || echo -e "${RED}ERROR:${NC} failed to restart Hysteria 2"; pause ;;
			5) journalctl --no-pager -e -u hysteria-server.service; pause ;;
			6) [ -f /etc/hysteria/config.yaml ] && cat /etc/hysteria/config.yaml || echo -e "${RED}ERROR:${NC} config not found"; pause ;;
			7) apps_remove_hysteria2; pause ;;
			0) break ;;
			*) echo -e "${RED}ERROR:${NC} invalid"; pause ;;
		esac
	done
}

# ===== MAIN =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	apps_hysteria2_menu
fi
