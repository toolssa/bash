#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода информации
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log() { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# 1. Проверка прав суперпользователя
[[ $EUID -eq 0 ]] || die "Этот скрипт необходимо запускать от имени root (через sudo)"

# 2. Автоматическое определение архитектуры процессора
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  MITA_ARCH="amd64" ;;
    aarch64) MITA_ARCH="arm64" ;;
    *) die "Архитектура процессора ($ARCH) не поддерживается данным скриптом." ;;
esac

log "Обнаружена архитектура: $MITA_ARCH"

# Проверка и пакетная установка базовых системных зависимостей
MISSING_CMDS=()
for cmd in curl tar openssl jq sudo; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -ne 0 ]; then
    if ! command -v apt-get &>/dev/null; then
        die "Отсутствуют необходимые утилиты (${MISSING_CMDS[*]}), и менеджер пакетов apt-get не найден. Скрипт ориентирован на Debian/Ubuntu."
    fi
    log "Установка недостающих утилит: ${MISSING_CMDS[*]}..."
    apt-get update -qq && apt-get install -y "${MISSING_CMDS[@]}" -qq >/dev/null
fi

# 3. Запрос к GitHub API с обработкой ошибок
log "Запрос информации о последнем релизе mita..."
REPO="enfein/mieru"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

LATEST_RELEASE_JSON=$(curl -s -f "$API_URL" || echo "{\"message\": \"HTTP_ERROR\"}")

API_MESSAGE=$(echo "$LATEST_RELEASE_JSON" | jq -r '.message // empty')
if [[ -n "$API_MESSAGE" ]]; then
    die "Не удалось получить данные из GitHub API (Ошибка: $API_MESSAGE). Возможно, превышен лимит запросов (Rate Limit)."
fi

LATEST_TAG=$(echo "$LATEST_RELEASE_JSON" | jq -r '.tag_name')
log "Найдена актуальная версия: $LATEST_TAG"

# 4. Строгий парсинг прямой ссылки на .tar.gz архив
DOWNLOAD_URL=$(echo "$LATEST_RELEASE_JSON" | jq -r --arg arch "$MITA_ARCH" '.assets[] | select(.name | test("^mita.*linux_" + $arch + "\\.tar\\.gz$")) | .browser_download_url' | head -n 1)

if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    die "Критическая ошибка: Не удалось найти подходящий архив (.tar.gz) для архитектуры linux_${MITA_ARCH}."
fi

# 5. Скачивание во временную директорию с гарантированной очисткой
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT # Удалит папку при любом исходе работы скрипта
cd "$TMP_DIR"
log "Скачивание релиза..."
curl -fSsLO "$DOWNLOAD_URL"

# 6. Распаковка и установка исполняемого файла
log "Распаковка и перенос бинарного файла..."
ARCHIVE=$(basename "$DOWNLOAD_URL")
tar -xzf "$ARCHIVE"

if [[ ! -f "mita" ]]; then
    die "Файл 'mita' не найден внутри скачанного архива."
fi

mv mita /usr/local/bin/mita
chmod +x /usr/local/bin/mita
log "Исполняемый файл успешно установлен в /usr/local/bin/mita"

# 7. Подготовка системного окружения и структуры директорий
log "Настройка системного пользователя и путей..."
mkdir -p /etc/mita
id -u mita &>/dev/null || useradd -r -s /bin/false mita

# Генерация безопасных учетных данных (без конфликтующих с JSON и CLI спецсимволов)
GEN_USER="mieru_user_$(openssl rand -hex 3)"
GEN_PASS=$(openssl rand -base64 24 | tr -d '/"+=')

# 8. Создание первичной конфигурации JSON
cat <<EOF > /etc/mita/server.json
{
  "portBindings": [
    { "portRange": "2012-2022", "protocol": "TCP" },
    { "portRange": "2012-2022", "protocol": "UDP" }
  ],
  "users": [
    { "name": "${GEN_USER}", "password": "${GEN_PASS}" }
  ]
}
EOF

# Выставляем права ДО применения конфига, чтобы тест от mita прошел успешно
chown -R mita:mita /etc/mita

# 9. Инициализация конфигурации через внутренний компилятор mita
log "Валидация и применение конфигурации..."
/usr/local/bin/mita apply config /etc/mita/server.json

if [[ -f /etc/mita/server.conf.pb ]]; then
    chown mita:mita /etc/mita/server.conf.pb
    chmod 600 /etc/mita/server.conf.pb
else
    die "Критическая ошибка: Бинарный файл конфигурации server.conf.pb не сгенерирован."
fi

# 10. Тестирование режима работы mita от имени пользователя mita
log "Тестирование режима запуска бинарника (Foreground vs Daemon)..."

# Запускаем тест от изолированного пользователя, чтобы права на файлы не улетели к root
sudo -u mita /usr/local/bin/mita start >/dev/null 2>&1 &
TEST_PID=$!

sleep 2

if kill -0 "$TEST_PID" 2>/dev/null; then
    log "Определен режим запуска: Foreground (Блокирующий). Используем команду 'start'."
    EXEC_CMD="/usr/local/bin/mita start"
    kill "$TEST_PID" 2>/dev/null || true
    sleep 1 # Даем ядру время освободить порты после теста
else
    warn "Команда 'mita start' уходит в фон или завершается. Переключаемся на резервный режим 'run'..."
    EXEC_CMD="/usr/local/bin/mita run"
fi

# 11. Создание и регистрация службы systemd
log "Регистрация службы systemd..."
cat <<EOF > /etc/systemd/system/mita.service
[Unit]
Description=mita proxy server (mieru)
After=network.target

[Service]
Type=simple
User=mita
Group=mita
WorkingDirectory=/etc/mita
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Запуск демона
systemctl daemon-reload
systemctl enable mita --now

# Финальная верификация статуса
sleep 2
if systemctl is-active --quiet mita; then
    echo -e "\n${GREEN}====================================================${RESET}"
    log "Сервер mita успешно развернут и запущен!"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "Данные для авторизации вашего клиента (mieru client):"
    echo -e "Пользователь (Username):  ${GEN_USER}"
    echo -e "Пароль (Password):        ${GEN_PASS}"
    echo -e "Порты (Ports):            2012-2022 (TCP/UDP мультипорт)"
    echo -e "Файл конфигурации:        /etc/mita/server.json"
    echo -e "${GREEN}====================================================${RESET}"
    warn "Убедитесь, что порты диапазона 2012-2022 открыты в UFW или внешнем файрволе провайдера!"
else
    die "Служба создана, но не смогла запуститься. Выполните для диагностики: journalctl -u mita -n 50"
fi