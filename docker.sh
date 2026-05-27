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
command_exists() {
	command -v "$1" >/dev/null 2>&1
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
	line=$(printf '─%.0s' $(seq 1 $((len + 4))))
	echo ""
	echo -e "${YELLOW}┌${line}┐${NC}"
	echo -e "${YELLOW}│  ${title}  │${NC}"
	echo -e "${YELLOW}└${line}┘${NC}"
}

print_menu_item() {
	local num="$1"
	local desc="$2"
	local color="${3:-$WHITE}"
	printf "${color}[%s]${NC} %s\n" "$num" "$desc"
}

# =========================
# DOCKER
# =========================

DOCKER_GPG="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"

remove_conflicting_packages() {
	echo -e "${YELLOW}[*]${NC} Removing conflicting packages..."

	# Изолируем grep внутри подоболочки, чтобы pipefail не ронял скрипт на чистой системе
	local CONFLICTING
	CONFLICTING=$(dpkg --get-selections 2>/dev/null | { grep -E 'docker.io|docker-compose|docker-doc|podman-docker|containerd|runc' || true; } | awk '{print $1}' | tr '\n' ' ')
	CONFLICTING=$(echo "$CONFLICTING" | xargs)

	if [ -n "$CONFLICTING" ]; then
		apt remove -y $CONFLICTING || true
		echo -e "${GREEN}OK:${NC} conflicting packages removed"
	else
		echo -e "${GRAY}No conflicting packages found${NC}"
	fi
}

add_docker_repository() {
	local CODENAME ARCH rc=0

	if ! grep -qi 'debian' /etc/os-release; then
		echo -e "${RED}ERROR:${NC} Debian required"
		return 1
	fi

	CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
	ARCH=$(dpkg --print-architecture)

	if [ -z "$CODENAME" ]; then
		echo -e "${RED}ERROR:${NC} could not detect Debian codename"
		return 1
	fi

	echo -e "${YELLOW}[*]${NC} Adding Docker repository..."

	apt update || true
	apt install -y ca-certificates curl || return 1

	install -m 0755 -d /etc/apt/keyrings

	curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_GPG" || return 1
	chmod a+r "$DOCKER_GPG"

	cat > "$DOCKER_SOURCES" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Architectures: $ARCH
Signed-By: $DOCKER_GPG
EOF

	apt update || rc=$?
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}OK:${NC} Docker repository added"
	else
		echo -e "${RED}ERROR:${NC} failed to update package index with Docker repo"
		return 1
	fi
}

install_docker_packages() {
	echo -e "${YELLOW}[*]${NC} Installing Docker packages..."
	local rc=0

	apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || rc=$?
	
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}OK:${NC} Docker packages installed"
	else
		echo -e "${RED}ERROR:${NC} failed to install Docker packages"
		return 1
	fi
}

add_user_to_docker_group() {
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
		getent group docker >/dev/null || groupadd docker
		usermod -aG docker "$SUDO_USER"
		echo -e "${GREEN}OK:${NC} user '$SUDO_USER' added to docker group"
		echo -e "${YELLOW}Notice:${NC} log out and log back in for group changes to take effect"
	fi
}

docker_install() {
	require_root

	if command_exists docker; then
		echo -e "${GREEN}OK:${NC} Docker already installed"
		return
	fi

	remove_conflicting_packages
	add_docker_repository || return
	install_docker_packages || return
	add_user_to_docker_group

	echo -e "${GREEN}OK:${NC} Docker installed successfully"
}

docker_remove() {
	require_root

	if ! confirm "Remove Docker completely?"; then
		return
	fi

	echo -e "${YELLOW}[*]${NC} Removing Docker packages and data..."

	# '|| true' гарантирует, что скрипт не вылетит, если что-то уже было удалено руками
	apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
	apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
	
	rm -rf /var/lib/docker /var/lib/containerd
	rm -f "$DOCKER_GPG" "$DOCKER_SOURCES"

	echo -e "${GREEN}OK:${NC} Docker completely removed"
}

docker_status() {
	echo "===== DOCKER STATUS ====="
	if command_exists docker; then
		docker --version
		systemctl is-active --quiet docker && echo "docker: running" || echo "docker: stopped"
		echo "Images: $(docker images -q 2>/dev/null | wc -l)"
		echo "Containers: $(docker ps -aq 2>/dev/null | wc -l)"
	else
		echo "docker: not installed"
	fi
}

docker_reference() {
	cat <<'EOF'
===== DOCKER REFERENCE =====
sudo docker ps
sudo docker ps -a
sudo docker images
sudo docker logs container_name
sudo docker exec -it container_name bash
sudo systemctl status docker
sudo docker compose up -d
docker info
EOF
}

docker_menu() {
	require_root

	while true; do
		clear
		menu_header "Docker Manager"
		echo ""
		print_menu_item "1" "Install Docker" "$GREEN"
		print_menu_item "2" "Remove Docker" "$RED"
		print_menu_item "3" "Status" "$CYAN"
		print_menu_item "4" "Reference" "$DIM"
		echo ""
		print_menu_item "0" "Back" "$GRAY"
		echo ""

		read -rp "Select: " c

		case "$c" in
			1) docker_install; pause ;;
			2) docker_remove; pause ;;
			3) docker_status; pause ;;
			4) docker_reference; pause ;;
			0) break ;;
			*) echo -e "${RED}ERROR:${NC} invalid"; pause ;;
		esac
	done
}

# ===== MAIN =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	ufw_menu
fi