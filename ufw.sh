#!/usr/bin/env bash
set -uo pipefail

# Корректный trap, который не будет мешать обработке логических ветвей
trap 'echo -e "\n${RED:-}ERROR on line ${LINENO}${NC:-}"' ERR

# =========================
# COLORS (Fixed ANSI sequences)
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# =========================
# UTILS
# =========================
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

confirm() {
	local prompt="$1" yn
	echo -en "${YELLOW}$prompt [y/N]: ${NC}"
	read -r yn
	[[ "$yn" =~ ^[Yy]$ ]]
}

pause() {
	echo ""
	echo -en "${DIM}Press Enter to continue...${NC}"
	read -r
}

require_root() {
	if [ "${EUID:-$(id -u)}" -ne 0 ]; then
		echo "Run as root" >&2
		exit 1
	fi
}

menu_header() {
	local title="$1"
	local len=${#title}
	local line
	line=$(printf '=%.0s' $(seq 1 $((len + 4))))
	echo ""
	echo -e "${YELLOW}┌${line}┐${NC}"
	echo -e "${YELLOW}│  ${title}  │${NC}"
	echo -e "${YELLOW}└${line}┘${NC}"
}

print_menu_item() {
	local num="$1" desc="$2" color="${3:-$WHITE}"
	printf "${color}[%s]${NC} %s\n" "$num" "$desc"
}

# =========================
# UFW
# =========================

ufw_ctrl() {
	local cmd="$1" desc="$2" flag="${3:-}"
	local rc=0
	
	if [ -n "$flag" ]; then
		ufw $flag "$cmd" || rc=$?
	else
		ufw "$cmd" || rc=$?
	fi
	
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}OK:${NC} UFW $desc"
	else
		echo -e "${RED}ERROR:${NC} failed to $desc"
	fi
	return $rc
}

ufw_install() {
	if command_exists ufw; then
		echo -e "${YELLOW}WARNING:${NC} UFW already installed"
		return
	fi
	apt install -y ufw && echo -e "${GREEN}OK:${NC} UFW installed" || echo -e "${RED}ERROR:${NC} failed to install UFW"
}

ufw_remove() {
	if ! command_exists ufw; then
		echo -e "${YELLOW}WARNING:${NC} UFW not installed"
		return
	fi
	apt remove -y ufw && echo -e "${GREEN}OK:${NC} UFW removed" || echo -e "${RED}ERROR:${NC} failed to remove UFW"
}

ufw_allow() {
	local P rc=0
	read -rp "Port/Service (e.g. 80, 2222/tcp, ssh, 3000:3005/tcp): " P
	P=$(echo "$P" | xargs)

	if [[ -z "$P" ]]; then
		echo -e "${RED}ERROR:${NC} input cannot be empty"
		return
	fi

	# Валидация портов, диапазонов, протоколов и популярных имен сервисов
	if [[ ! "$P" =~ ^[0-9]+(/tcp|/udp)?$ ]] && \
	   [[ ! "$P" =~ ^[0-9]+:[0-9]+(/tcp|/udp)?$ ]] && \
	   [[ ! "$P" =~ ^[a-zA-Z_-]+$ ]]; then
		echo -e "${RED}ERROR:${NC} invalid port or service format"
		return
	fi

	ufw allow "$P" || rc=$?
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}OK:${NC} rule added: $P"
	else
		echo -e "${RED}ERROR:${NC} failed to add rule: $P"
	fi
}

ufw_delete() {
	local input out rc=0 deleted=0
	ufw status numbered || true
	echo ""
	read -rp "Delete by number (e.g. 3) or rule (e.g. 80/tcp): " input
	input=$(echo "$input" | xargs)

	if [[ -z "$input" ]]; then
		echo -e "${RED}ERROR:${NC} input cannot be empty"
		return
	fi

	# Снимаем квадратные скобки, если пользователь всё же ввёл их типа [3]
	if [[ "$input" =~ ^\[[0-9]+\]$ ]]; then
		input="${input#[}"; input="${input%]}"
	fi

	# Сценарий 1: Удаление по порядковому номеру правила из списка ufw status numbered
	if [[ "$input" =~ ^[0-9]+$ ]] && [ "${#input}" -le 3 ]; then
		out=$(ufw --force delete "$input" 2>&1) || rc=$?
		if [ $rc -eq 0 ]; then
			echo "$out"
			echo -e "${GREEN}OK:${NC} rule #$input deleted"
		else
			echo "$out"
			echo -e "${RED}ERROR:${NC} failed to delete rule #$input"
		fi
		return
	fi

	# Сценарий 2: Удаление по чистому номеру порта (пробуем поочередно tcp и udp)
	if [[ "$input" =~ ^[0-9]+$ ]]; then
		for proto in tcp udp; do
			out=$(ufw delete allow "$input/$proto" 2>&1) || rc=$?
			if [ $rc -eq 0 ]; then
				echo -e "${GREEN}OK:${NC} rule $input/$proto deleted"
				deleted=1
			fi
		done
		if [ $deleted -eq 0 ]; then
			echo -e "${RED}ERROR:${NC} no rule found or failed to delete port $input"
		fi
		return
	fi

	# Сценарий 3: Удаление по полной спецификации правила (например, 80/tcp или названия сервиса)
	out=$(ufw delete allow "$input" 2>&1) || rc=$?
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}OK:${NC} rule '$input' deleted"
	else
		echo -e "${RED}ERROR:${NC} failed to delete rule '$input'"
		echo "$out"
	fi
}

ufw_status() {
	echo "===== UFW STATUS ====="
	ufw status verbose || true
}

ufw_reference() {
	cat <<'EOF'
===== UFW REFERENCE =====
sudo ufw allow 80
sudo ufw allow 2222/tcp
sudo ufw status numbered
sudo ufw delete 3
sudo ufw delete allow 80/tcp
sudo ufw enable
sudo ufw disable
sudo ufw --force reset
EOF
}

ufw_menu() {
	require_root
	while true; do
		clear
		menu_header "UFW Firewall"
		echo ""
		print_menu_item "1" "Install" "$GREEN"
		print_menu_item "2" "Remove" "$RED"
		echo ""
		print_menu_item "3" "Enable" "$GREEN"
		print_menu_item "4" "Disable" "$RED"
		print_menu_item "5" "Status" "$CYAN"
		echo ""
		print_menu_item "6" "Default deny incoming" "$YELLOW"
		print_menu_item "7" "Default allow outgoing" "$YELLOW"
		echo ""
		print_menu_item "8" "Allow port" "$CYAN"
		print_menu_item "9" "Delete rule" "$YELLOW"
		print_menu_item "10" "Reset" "$RED"
		print_menu_item "11" "Logging on" "$DIM"
		print_menu_item "12" "Logging off" "$DIM"
		echo ""
		print_menu_item "r" "Reference" "$DIM"
		print_menu_item "0" "Back" "$GRAY"
		echo ""

		read -rp "Select: " c

		case "$c" in
			1) ufw_install; pause ;;
			2) confirm "Remove UFW?" && ufw_remove; pause ;;
			3) ufw_ctrl "enable" "enabled" "--force"; pause ;;
			4) ufw_ctrl "disable" "disabled"; pause ;;
			5) ufw_status; pause ;;
			6) ufw_ctrl "default deny incoming" "default deny incoming"; pause ;;
			7) ufw_ctrl "default allow outgoing" "default allow outgoing"; pause ;;
			8) ufw_allow; pause ;;
			9) ufw_delete; pause ;;
			10) confirm "Reset UFW? All rules will be deleted" && ufw_ctrl "reset" "reset" "--force"; pause ;;
			11) ufw_ctrl "logging on" "logging enabled"; pause ;;
			12) ufw_ctrl "logging off" "logging disabled"; pause ;;
			r) ufw_reference; pause ;;
			0) break ;;
			*) echo -e "${RED}ERROR:${NC} invalid"; pause ;;
		esac
	done
}

# ===== MAIN =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	ufw_menu
fi