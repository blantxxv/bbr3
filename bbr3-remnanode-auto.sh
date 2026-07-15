#!/usr/bin/env bash

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")

SCRIPT_VERSION="2.6.1"

STATE_DIR="/var/lib/bbr3-remnanode"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/bbr3-remnanode-install.log"
SCRIPT_PATH="/usr/local/sbin/bbr3-remnanode-install.sh"
PROFILE_HOOK="/etc/profile.d/bbr3-remnanode-continue.sh"

SELF_DOWNLOAD_URL="https://raw.githubusercontent.com/blantxxv/bbr3/refs/heads/main/bbr3-remnanode-auto.sh"
WARP_INSTALL_URL="https://raw.githubusercontent.com/blantxxv/warp/main/warp-auto-install.sh"
TORRENT_BLOCKER_INSTALL_URL="https://raw.githubusercontent.com/mahmudali1337-lab/torrent-blocker/master/install.sh"
TORRENT_BLOCKER_BIN="/usr/local/bin/torrent-blocker"

CPU_LEVEL=""
KERNEL_INSTALL_SKIPPED=0

KERNEL_VER="6.19.14-x64v3-xanmod1"
XANMOD_BASE_URL="https://deb.xanmod.org/pool/main/l/linux-upstream"
IMAGE_DEB_URL="$XANMOD_BASE_URL/linux-image-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb"
HEADERS_DEB_URL="$XANMOD_BASE_URL/linux-headers-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb"

OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""

DEFAULT_NODE_PORT="2222"
REMNANODE_DIR=""
REMNANODE_LOG_DIR=""
NODE_PORT=""
NODE_DISPLAY_NAME=""
COMPOSE_PROJECT_NAME=""
CONTAINER_NAME=""

# Тип установки: "reality" (TCP+REALITY, как раньше) или "tls" (TCP+TLS со своим доменом)
NODE_INSTALL_TYPE=""
INSTALL_TYPE_FILE="$STATE_DIR/install_type"

DOMAIN=""
CERT_DIR=""
CERT_OK=0
DOMAIN_FILE="$STATE_DIR/domain"

# Список публичных зеркал Docker Hub на случай, если registry-1.docker.io
# отдаёт 403/недоступен (блокировка/rate limit). Пробуем по очереди.
DOCKER_HUB_MIRRORS=(
  "mirror.gcr.io"
  "dockerhub.timeweb.cloud"
)

DEFAULT_TLS_VLESS_PORT="443"
DEFAULT_HY2_PORT="7443"
TLS_VLESS_PORT=""
HY2_PORT=""

RU_GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat"
RU_GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"

DEBUG="${DEBUG:-0}"

# Старые curl (например, 7.58 на Ubuntu 18.04) не знают флаг --retry-all-errors
# (появился в curl 7.71). Проверяем поддержку один раз и используем этот флаг
# только если он реально есть, иначе просто опускаем его во всех вызовах curl.
CURL_RETRY_ALL_ERRORS_FLAG=""
if curl --retry-all-errors --version >/dev/null 2>&1; then
  CURL_RETRY_ALL_ERRORS_FLAG="--retry-all-errors"
fi

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

SPINNER_PID=""

cleanup_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  SPINNER_PID=""
}

trap cleanup_spinner EXIT

print_banner() {
  clear 2>/dev/null || true

  cat <<BANNER
${C_CYAN}${C_BOLD}
┌──────────────────────────────────────────────────────────────┐
│                    Eclipse Node Manager                      │
│                  BBR3 + Remnawave Node Setup                 │
│              XanMod Kernel · Network Tuning · Docker         │
│                    Channel: t.me/light_eclipse               │
└──────────────────────────────────────────────────────────────┘
${C_RESET}
${C_DIM}Версия скрипта: $SCRIPT_VERSION${C_RESET}
${C_DIM}Log file: $LOG_FILE${C_RESET}

BANNER
}

section() {
  echo
  echo "${C_BLUE}${C_BOLD}▶ $*${C_RESET}"
}

info() {
  echo "${C_DIM}  $*${C_RESET}"
}

ok() {
  echo "${C_GREEN}  [ OK ]${C_RESET} $*"
}

warn() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo -e "[$(date '+%F %T')] [WARN] $*" >> "$LOG_FILE" 2>/dev/null || true
  echo "${C_YELLOW}  [WARN]${C_RESET} $*"
}

fail() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo -e "[$(date '+%F %T')] [ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true
  echo "${C_RED}  [FAIL]${C_RESET} $*"
}

die() {
  fail "$*"
  echo
  echo "${C_DIM}Подробный лог: $LOG_FILE${C_RESET}"
  exit 1
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo -e "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

spinner() {
  local msg="$1"
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while true; do
    printf "\r${C_CYAN}  [%s]${C_RESET} %s" "${chars:i++%${#chars}:1}" "$msg"
    sleep 0.1
  done
}

show_last_log() {
  echo
  echo "${C_DIM}Последние строки лога:${C_RESET}"
  tail -n 40 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || true
}

run_cmd() {
  local msg="$1"
  shift

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START: $msg"
  log_line "CMD: $*"

  if [[ "$DEBUG" == "1" ]]; then
    echo "${C_CYAN}  [..]${C_RESET} $msg"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    if [[ "$rc" -eq 0 ]]; then
      ok "$msg"
      log_line "OK: $msg"
      return 0
    fi
    fail "$msg"
    log_line "FAIL: $msg rc=$rc"
    return "$rc"
  fi

  spinner "$msg" &
  SPINNER_PID="$!"

  set +e
  "$@" >> "$LOG_FILE" 2>&1
  local rc="$?"
  set -e

  cleanup_spinner
  printf "\r\033[K"

  if [[ "$rc" -eq 0 ]]; then
    ok "$msg"
    log_line "OK: $msg"
    return 0
  fi

  fail "$msg"
  log_line "FAIL: $msg rc=$rc"
  show_last_log
  return "$rc"
}

run_shell() {
  local msg="$1"
  local cmd="$2"

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START: $msg"
  log_line "SHELL: $cmd"

  if [[ "$DEBUG" == "1" ]]; then
    echo "${C_CYAN}  [..]${C_RESET} $msg"
    bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    if [[ "$rc" -eq 0 ]]; then
      ok "$msg"
      log_line "OK: $msg"
      return 0
    fi
    fail "$msg"
    log_line "FAIL: $msg rc=$rc"
    return "$rc"
  fi

  spinner "$msg" &
  SPINNER_PID="$!"

  set +e
  bash -lc "$cmd" >> "$LOG_FILE" 2>&1
  local rc="$?"
  set -e

  cleanup_spinner
  printf "\r\033[K"

  if [[ "$rc" -eq 0 ]]; then
    ok "$msg"
    log_line "OK: $msg"
    return 0
  fi

  fail "$msg"
  log_line "FAIL: $msg rc=$rc"
  show_last_log
  return "$rc"
}

run_shell_live() {
  local msg="$1"
  local cmd="$2"

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START LIVE: $msg"
  log_line "SHELL LIVE: $cmd"

  echo "${C_CYAN}  [..]${C_RESET} $msg"
  echo "${C_DIM}  ────────────────────────────────────────────────────────────${C_RESET}"

  set +e
  bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
  local rc="${PIPESTATUS[0]}"
  set -e

  echo "${C_DIM}  ────────────────────────────────────────────────────────────${C_RESET}"

  if [[ "$rc" -eq 0 ]]; then
    ok "$msg"
    log_line "OK LIVE: $msg"
    return 0
  fi

  fail "$msg"
  log_line "FAIL LIVE: $msg rc=$rc"
  show_last_log
  return "$rc"
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

set_state() {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$STATE_FILE"
}

get_state() {
  cat "$STATE_FILE" 2>/dev/null || true
}

save_install_type() {
  mkdir -p "$STATE_DIR"
  echo "$NODE_INSTALL_TYPE" > "$INSTALL_TYPE_FILE"
}

# Загружает NODE_INSTALL_TYPE из файла состояния (нужно после reboot, когда
# процесс скрипта, где спрашивали тип установки, уже завершился).
# Если файла нет или значение битое — переспрашивает у пользователя.
load_install_type() {
  if [[ -f "$INSTALL_TYPE_FILE" ]]; then
    NODE_INSTALL_TYPE="$(cat "$INSTALL_TYPE_FILE" 2>/dev/null || true)"
  fi

  if [[ "$NODE_INSTALL_TYPE" != "reality" && "$NODE_INSTALL_TYPE" != "tls" ]]; then
    warn "Тип установки ноды не найден в сохранённом состоянии."
    ask_node_install_type
  fi
}

save_domain() {
  mkdir -p "$STATE_DIR"
  echo "$DOMAIN" > "$DOMAIN_FILE"
}

# Проверяет, есть ли уже действующий (не истекающий в ближайшие сутки)
# сертификат Let's Encrypt для указанного домена.
check_existing_certificate() {
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live/$domain"

  [[ -n "$domain" ]] || return 1
  [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]] || return 1

  openssl x509 -checkend 86400 -noout -in "$cert_dir/fullchain.pem" >/dev/null 2>&1
}

# Ищет на диске все домены под /etc/letsencrypt/live с действующим
# сертификатом — на случай, если сертификат выпустили в прошлом запуске
# скрипта (например, до этой версии, или установка ноды упала уже после
# выпуска сертификата), и файла состояния с доменом ещё нет.
find_existing_certificates() {
  local d domain

  [[ -d /etc/letsencrypt/live ]] || return 0

  for d in /etc/letsencrypt/live/*/; do
    [[ -d "$d" ]] || continue
    domain="$(basename "$d")"

    if check_existing_certificate "$domain"; then
      echo "$domain"
    fi
  done
}

detect_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "Docker Compose не найден. Нужен docker compose plugin или docker-compose." >&2
    return 127
  fi
}

docker_compose_version_safe() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose version 2>/dev/null | head -n 1
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose version 2>/dev/null | head -n 1
    return 0
  fi

  echo "Docker Compose не найден"
  return 0
}

download_self_latest() {
  local target="$1"
  local tmp

  mkdir -p "$(dirname "$target")"
  cleanup_old_script_copies "$target" || true
  tmp="$(mktemp "${target}.tmp.XXXXXX")"

  if ! curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    -o "$tmp" \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi

  if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
    rm -f "$tmp"
    die "Скачанный скрипт не прошёл bash -n. Обновление отменено."
  fi

  mv -f "$tmp" "$target"
  chmod 700 "$target"
}

ensure_saved_script_is_latest() {
  local current_src current_version current_hash remote_content remote_version remote_hash tmp

  current_src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  mkdir -p "$(dirname "$SCRIPT_PATH")"

  # Сначала сохраняем именно текущий запущенный файл. Это защищает от отката,
  # если GitHub/CDN ещё отдаёт старую версию.
  if [[ -n "$current_src" && -f "$current_src" && -r "$current_src" ]]; then
    cleanup_old_script_copies || true
    tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")"

    if ! cp -- "$current_src" "$tmp"; then
      rm -f "$tmp"
      die "Не удалось скопировать текущий скрипт в временный файл."
    fi

    if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
      rm -f "$tmp"
      die "Текущий локальный скрипт не прошёл bash -n. Не сохраняю его в $SCRIPT_PATH."
    fi

    mv -f "$tmp" "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"
    ok "Системная копия скрипта сохранена из текущего файла: $SCRIPT_PATH"
  fi

  remote_content="$(fetch_remote_script)"
  [[ -n "$remote_content" ]] || {
    warn "GitHub недоступен. Для продолжения после reboot сохранена текущая локальная копия."
    [[ -s "$SCRIPT_PATH" ]] || die "Нет локальной копии скрипта для продолжения после reboot."
    return 0
  }

  remote_version="$(extract_script_version "$remote_content" || true)"
  remote_hash="$(sha256_text "$remote_content" 2>/dev/null || true)"

  current_version="$SCRIPT_VERSION"
  current_hash=""
  if [[ -s "$SCRIPT_PATH" ]]; then
    current_hash="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -n "$remote_version" ]] && version_gt "$remote_version" "$current_version"; then
    cleanup_old_script_copies || true
    tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")"
    printf '%s\n' "$remote_content" > "$tmp"

    if [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"
      warn "Удалённый скрипт пустой. Оставляю текущую локальную копию."
      return 0
    fi

    if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
      rm -f "$tmp"
      warn "Удалённый скрипт новее, но не прошёл bash -n. Оставляю текущую локальную копию."
      return 0
    fi

    mv -f "$tmp" "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"
    ok "Системная копия обновлена с GitHub до версии $remote_version"
    return 0
  fi

  if [[ -n "$current_hash" && -n "$remote_hash" && "$remote_hash" != "$current_hash" && "$remote_version" == "$current_version" ]]; then
    warn "На GitHub файл отличается при той же версии $current_version. Не перезаписываю локальную копию автоматически."
  fi

  [[ -s "$SCRIPT_PATH" ]] || die "Не удалось подготовить системную копию скрипта."
}

save_self() {
  ensure_saved_script_is_latest
}

# Возвращает успех (0), если версия $1 строго новее версии $2.
version_gt() {
  local a="${1:-}" b="${2:-}"

  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$a" == "$b" ]] && return 1

  local lower
  lower="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)"

  [[ "$lower" == "$b" ]]
}
fetch_remote_script() {
  curl -fsSL --connect-timeout 5 --max-time 20 --retry 3 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)" 2>/dev/null || true
}

extract_script_version() {
  awk -F'"' '/^SCRIPT_VERSION=/{print $2; found=1; exit} END{if (!found) exit 0}' <<< "${1:-}"
}

# Подчищает старые/временные копии скрипта, чтобы не было конфликта версий.
cleanup_old_script_copies() {
  local keep="${1:-}"
  local f

  rm -f "${SCRIPT_PATH}.bak" 2>/dev/null || true

  for f in "${SCRIPT_PATH}".tmp.*; do
    [[ -e "$f" ]] || continue
    [[ -n "$keep" && "$f" == "$keep" ]] && continue
    rm -f "$f" 2>/dev/null || true
  done
}

current_script_path() {
  local src
  src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

  if [[ -n "$src" && -r "$src" ]]; then
    echo "$src"
    return 0
  fi

  if [[ -r "$SCRIPT_PATH" ]]; then
    echo "$SCRIPT_PATH"
    return 0
  fi

  return 1
}

sha256_text() {
  printf '%s\n' "$1" | sha256sum | awk '{print $1}'
}

short_hash() {
  local h="${1:-}"
  [[ -n "$h" ]] && echo "${h:0:12}" || echo "unknown"
}

update_self_and_restart() {
  local remote_content="$1"
  local tmp

  mkdir -p "$(dirname "$SCRIPT_PATH")"
  cleanup_old_script_copies || true
  tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")"
  printf '%s\n' "$remote_content" > "$tmp"

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    die "Скачанный скрипт пустой. Обновление отменено."
  fi

  if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
    rm -f "$tmp"
    die "Скачанный скрипт не прошёл проверку синтаксиса (bash -n). Обновление отменено."
  fi

  mv -f "$tmp" "$SCRIPT_PATH"
  chmod 700 "$SCRIPT_PATH"

  ok "Скрипт обновлён. Перезапускаю новую версию..."
  log_line "Self-update: restarting via $SCRIPT_PATH ${ORIGINAL_ARGS[*]:-}"
  exec "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

check_for_updates() {
  section "Проверка обновлений"

  local remote_content remote_version remote_hash current_src local_hash ans same_version

  remote_content="$(fetch_remote_script)"

  if [[ -z "$remote_content" ]]; then
    warn "Не удалось получить актуальную версию скрипта с GitHub. Проверь сеть и попробуй позже."
    return 1
  fi

  remote_version="$(extract_script_version "$remote_content" || true)"

  if [[ -z "$remote_version" ]]; then
    warn "Не удалось определить версию в скачанном скрипте."
    return 1
  fi

  remote_hash="$(sha256_text "$remote_content" 2>/dev/null || true)"
  current_src="$(current_script_path || true)"
  local_hash=""

  if [[ -n "$current_src" && -r "$current_src" ]]; then
    local_hash="$(sha256sum "$current_src" 2>/dev/null | awk '{print $1}' || true)"
  fi

  ok "Текущая версия: $SCRIPT_VERSION"
  ok "Версия на GitHub: $remote_version"
  info "Локальный файл: ${current_src:-unknown}"
  info "Локальный SHA256: $(short_hash "$local_hash")"
  info "GitHub SHA256: $(short_hash "$remote_hash")"

  if [[ -n "$local_hash" && -n "$remote_hash" && "$remote_hash" == "$local_hash" ]]; then
    ok "Установлен актуальный файл скрипта."
    return 0
  fi

  same_version=0
  [[ "$remote_version" == "$SCRIPT_VERSION" ]] && same_version=1

  if version_gt "$remote_version" "$SCRIPT_VERSION"; then
    echo
    warn "Доступна новая версия скрипта: $remote_version (у тебя $SCRIPT_VERSION)."
  elif [[ "$same_version" -eq 1 ]]; then
    echo
    warn "На GitHub файл отличается от локального, хотя версия одинаковая: $SCRIPT_VERSION."
    warn "Такое бывает, если изменили код, но не подняли SCRIPT_VERSION."
  else
    echo
    warn "Версия на GitHub не новее локальной ($remote_version vs $SCRIPT_VERSION). Автообновление не рекомендовано."
    warn "Если ты точно хочешь заменить локальный файл удалённым — подтверди вручную."
  fi

  read -rp "  Установить файл с GitHub сейчас? [y/N]: " ans

  case "${ans,,}" in
    y|yes|д|да)
      update_self_and_restart "$remote_content"
      ;;
    *)
      ok "Обновление отложено."
      ;;
  esac
}

# Тихая проверка обновлений для главного меню: не блокирует, не спрашивает,
# просто подсказывает, что есть новая версия или отличается файл (пункт меню "5").
notify_if_update_available() {
  local remote_content remote_version remote_hash current_src local_hash

  remote_content="$(curl -fsSL --connect-timeout 2 --max-time 4 \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)" 2>/dev/null || true)"

  [[ -n "$remote_content" ]] || return 0

  remote_version="$(extract_script_version "$remote_content" || true)"
  [[ -n "$remote_version" ]] || return 0

  remote_hash="$(sha256_text "$remote_content" 2>/dev/null || true)"
  current_src="$(current_script_path || true)"
  local_hash=""

  if [[ -n "$current_src" && -r "$current_src" ]]; then
    local_hash="$(sha256sum "$current_src" 2>/dev/null | awk '{print $1}' || true)"
  fi

  if version_gt "$remote_version" "$SCRIPT_VERSION"; then
    echo "${C_YELLOW}  Доступна новая версия: $remote_version (у тебя $SCRIPT_VERSION). Пункт меню «5» — обновить.${C_RESET}"
    echo
    return 0
  fi

  if [[ -n "$local_hash" && -n "$remote_hash" && "$remote_version" == "$SCRIPT_VERSION" && "$remote_hash" != "$local_hash" ]]; then
    echo "${C_YELLOW}  На GitHub отличается файл той же версии $SCRIPT_VERSION. Пункт меню «5» — проверить обновления.${C_RESET}"
    echo
  fi
}


# Определяет дистрибутив/версию из /etc/os-release и сохраняет в OS_*.
# Нужно, чтобы видеть, на чём именно запускается скрипт (старые Ubuntu/Debian
# часто не имеют в репах свежих пакетов вроде btop).
detect_os_info() {
  section "Информация об ОС"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
    OS_CODENAME="unknown"
    OS_PRETTY_NAME="unknown"
  fi

  ok "ОС: $OS_PRETTY_NAME"
  info "id=$OS_ID · version_id=$OS_VERSION_ID · codename=$OS_CODENAME"
  log_line "OS detected: $OS_PRETTY_NAME (id=$OS_ID version_id=$OS_VERSION_ID codename=$OS_CODENAME)"

  if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    warn "Скрипт разрабатывался для Ubuntu/Debian. Обнаружено: $OS_PRETTY_NAME. Некоторые шаги могут не сработать."
  fi
}

# Возвращает успех, если пакет присутствует в подключённых APT-репозиториях
# (не факт, что установится, но хотя бы известен apt).
apt_package_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

# Фильтрует список пакетов, оставляя только доступные в текущих репозиториях
# этой ОС/версии. На старых релизах (например, Ubuntu 18.04) части пакетов
# вроде btop может не быть — пропускаем их с предупреждением вместо того,
# чтобы валить всю установку через один общий apt-get install.
filter_available_packages() {
  local pkg

  for pkg in "$@"; do
    if apt_package_available "$pkg"; then
      echo "$pkg"
    else
      warn "Пакет '$pkg' недоступен в репозиториях этой ОС (${OS_PRETTY_NAME:-неизвестно}) — пропускаю." >&2
    fi
  done
}

clean_bad_docker_apt_sources() {
  section "Проверка APT репозиториев"

  local bad_files invalid_files backup_dir f changed=0 ts
  ts="$(date +%s)"
  backup_dir="/etc/apt/sources.list.d.disabled-by-eclipse"

  mkdir -p "$backup_dir"

  bad_files="$(grep -rl "download.docker.com/linux/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"
  invalid_files="$(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name "*.disabled*" -o -name "*.bak*" -o -name "*.save*" \) 2>/dev/null || true)"

  if [[ -z "$bad_files" && -z "$invalid_files" ]]; then
    ok "Проблемные Docker/backup APT sources не найдены"
    return 0
  fi

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue

    if [[ "$f" == "/etc/apt/sources.list" ]]; then
      warn "Комментирую неправильные Docker Ubuntu строки в $f"
      cp -a "$f" "$backup_dir/sources.list.bak.$ts"
      sed -i '/download\.docker\.com\/linux\/ubuntu/s/^/# disabled by Eclipse Node Manager: /' "$f"
      changed=1
      continue
    fi

    warn "Переношу неправильный Docker Ubuntu repo: $f"
    mv -f "$f" "$backup_dir/$(basename "$f").$ts"
    changed=1
  done <<< "$bad_files"

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -e "$f" ]] || continue

    warn "Убираю backup-файл из sources.list.d, чтобы apt не ругался: $f"
    mv -f "$f" "$backup_dir/$(basename "$f").$ts"
    changed=1
  done <<< "$invalid_files"

  if [[ "$changed" -eq 1 ]]; then
    ok "APT sources очищены"
  fi
}

ask_node_install_type() {
  section "Тип установки ноды"

  echo
  echo "  Выбери, как настраивать транспорт ноды:"
  echo
  echo "  ${C_GREEN}1${C_RESET}) TCP + REALITY  ${C_DIM}(как раньше: маскировка через selfsteal.sh)${C_RESET}"
  echo "  ${C_GREEN}2${C_RESET}) TCP + TLS      ${C_DIM}(свой домен, сертификат Let's Encrypt через certbot)${C_RESET}"
  echo

  local choice
  while true; do
    read -rp "  Выбор [1/2]: " choice

    case "${choice:-}" in
      1)
        NODE_INSTALL_TYPE="reality"
        ok "Выбран тип установки: TCP + REALITY"
        break
        ;;
      2)
        NODE_INSTALL_TYPE="tls"
        ok "Выбран тип установки: TCP + TLS"
        break
        ;;
      *)
        warn "Некорректный выбор. Введи 1 или 2."
        ;;
    esac
  done

  save_install_type
}

install_base_packages() {
  section "1/12 · Базовые пакеты"

  detect_os_info
  clean_bad_docker_apt_sources

  run_cmd "Обновляю APT index" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update

  local packages=(
    curl wget gpg ca-certificates nano vim htop btop git unzip jq
    dnsutils iperf3 mtr-tiny iproute2 net-tools iptables ipset conntrack
    openssl python3 file
  )

  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    packages+=(certbot)
    info "Тип установки TLS: дополнительно ставлю certbot."
  fi

  local available_packages=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && available_packages+=("$pkg")
  done < <(filter_available_packages "${packages[@]}")

  [[ "${#available_packages[@]}" -gt 0 ]] || die "Ни один из требуемых пакетов не найден в репозиториях этой ОС. Проверь APT sources."

  run_cmd "Устанавливаю утилиты" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${available_packages[@]}"
}

check_cpu_level() {
  section "2/12 · Проверка CPU level"

  local level
  level="$(awk 'BEGIN{
    while(!/flags/) if (getline<"/proc/cpuinfo"!=1) exit;
    level=1;
    if(/lm/&&/cmov/&&/cx16/&&/sse4_1/&&/sse4_2/&&/ssse3/&&/popcnt/) level=2;
    if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/) level=3;
    if(level==3&&/avx512f/&&/avx512bw/) level=4;
    print "v"level
  }')"

  CPU_LEVEL="${level:-v1}"

  ok "Detected CPU level: ${CPU_LEVEL}"

  if [[ "$CPU_LEVEL" == "v1" || "$CPU_LEVEL" == "v2" ]]; then
    warn "CPU level ${CPU_LEVEL} не поддерживает x64v3. Установка XanMod x64v3 ядра будет пропущена (на v1/v2 это ломает загрузку сервера)."
  else
    info "Ставим x64v3. Это обычно стабильнее для VPS."
  fi

  log_line "Detected CPU level: ${CPU_LEVEL}"
}

install_xanmod_kernel() {
  section "3/12 · XanMod kernel $KERNEL_VER"

  if [[ "$CPU_LEVEL" == "v1" || "$CPU_LEVEL" == "v2" ]]; then
    KERNEL_INSTALL_SKIPPED=1
    warn "Пропускаю установку XanMod x64v3 ядра: CPU level ${CPU_LEVEL:-unknown} ниже требуемого v3."
    info "Сервер останется на текущем ядре, BBR v3 тюнинг сети при этом всё равно применится там, где это поддерживается текущим ядром."
    return 0
  fi

  KERNEL_INSTALL_SKIPPED=0

  if uname -r | grep -q "$KERNEL_VER"; then
    ok "Уже загружено нужное ядро: $(uname -r)"
    return 0
  fi

  mkdir -p /root/xanmod
  cd /root/xanmod

  rm -f ./*.deb

  run_cmd "Скачиваю linux-image XanMod" \
    curl -fL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG -o image.deb "$IMAGE_DEB_URL"

  run_cmd "Скачиваю linux-headers XanMod" \
    curl -fL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG -o headers.deb "$HEADERS_DEB_URL"

  run_shell "Проверяю deb-пакеты" "file /root/xanmod/image.deb /root/xanmod/headers.deb && dpkg-deb -I /root/xanmod/image.deb >/dev/null && dpkg-deb -I /root/xanmod/headers.deb >/dev/null"

  run_cmd "Устанавливаю XanMod kernel" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" ./image.deb ./headers.deb
  run_cmd "Обновляю GRUB" update-grub
}

install_profile_continue_hook() {
  section "Автопродолжение после reboot"

  cat > "$PROFILE_HOOK" <<EOF_HOOK
#!/usr/bin/env bash

case "\$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

tty -s || { return 0 2>/dev/null || exit 0; }

version_gt_hook() {
  local a="\$1" b="\$2" lower
  [[ "\$a" == "\$b" ]] && return 1
  lower="\$(printf '%s\n%s\n' "\$a" "\$b" | sort -V | head -n 1)"
  [[ "\$lower" == "\$b" ]]
}

extract_script_version_hook() {
  grep -m1 '^SCRIPT_VERSION=' "\$1" 2>/dev/null | sed -E 's/^SCRIPT_VERSION="([^"]*)".*/\1/'
}

if [[ "\$EUID" -eq 0 ]] && [[ -f "$STATE_FILE" ]] && grep -qx 'need_post_reboot' "$STATE_FILE"; then
  echo
  echo "Eclipse Node Manager: найдено незавершённое продолжение после reboot."
  echo "Проверяю обновление скрипта перед продолжением..."

  tmp="\$(mktemp "$SCRIPT_PATH.tmp.XXXXXX")"

  if curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    -o "\$tmp" \
    "$SELF_DOWNLOAD_URL?ts=\$(date +%s)" && bash -n "\$tmp"; then

    remote_version="\$(extract_script_version_hook "\$tmp")"
    local_version="\$(extract_script_version_hook "$SCRIPT_PATH")"
    remote_hash="\$(sha256sum "\$tmp" | awk '{print \$1}')"
    local_hash="\$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print \$1}')"

    if [[ -n "\$remote_version" ]] && { version_gt_hook "\$remote_version" "\${local_version:-0.0.0}" || [[ "\$remote_version" == "\$local_version" && "\$remote_hash" != "\$local_hash" ]]; }; then
      mv -f "\$tmp" "$SCRIPT_PATH"
      chmod 700 "$SCRIPT_PATH"
      echo "Скрипт обновлён до версии \$remote_version."
    else
      rm -f "\$tmp"
      echo "Сохранённая локальная копия не старее GitHub. Продолжаю ей."
    fi
  else
    rm -f "\$tmp"
    echo "Не удалось обновить скрипт. Продолжаю сохранённой копией."
  fi

  "$SCRIPT_PATH" --continue
fi
EOF_HOOK

  chmod 755 "$PROFILE_HOOK"
  ok "Hook создан: $PROFILE_HOOK"
}


maybe_reboot() {
  if [[ "$KERNEL_INSTALL_SKIPPED" -eq 1 ]]; then
    ok "Ребут не требуется: установка XanMod ядра была пропущена (CPU level ${CPU_LEVEL:-unknown})."
    return 0
  fi

  if uname -r | grep -q "$KERNEL_VER"; then
    ok "Ребут не нужен, уже загружено ядро $KERNEL_VER"
    return 0
  fi

  set_state "need_post_reboot"
  install_profile_continue_hook

  echo
  echo "${C_YELLOW}${C_BOLD}Первый этап завершён. Сейчас будет reboot.${C_RESET}"
  echo "${C_DIM}После ребута зайди снова по SSH под root — скрипт сам продолжится и попросит SECRET_KEY.${C_RESET}"
  echo

  sleep 5
  reboot
}

apply_network_tuning() {
  section "4/12 · Сетевой тюнинг"

  modprobe tcp_bbr >> "$LOG_FILE" 2>&1 || true

  cat >/etc/sysctl.d/99-net-tuning.conf <<'EOF_SYSCTL'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 4194304

net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.somaxconn = 65535

net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_max_orphans = 262144

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_min_snd_mss = 512
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 4

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7440

fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 1048576

vm.swappiness = 10
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.min_free_kbytes = 131072
EOF_SYSCTL

  run_cmd "Применяю sysctl параметры" sysctl --system

  local cc qdisc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  ok "TCP congestion control: ${cc:-unknown}"
  ok "Default qdisc: ${qdisc:-unknown}"
}

disable_thp() {
  section "5/12 · Transparent Huge Pages"

  cat >/etc/systemd/system/disable-thp.service <<'EOF_SERVICE'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -w /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true; [ -w /sys/kernel/mm/transparent_hugepage/defrag ] && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  run_cmd "Включаю disable-thp.service" systemctl daemon-reload
  run_cmd "Отключаю THP" systemctl enable --now disable-thp.service

  local thp
  thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
  ok "THP: ${thp:-unknown}"
}

enable_rps() {
  section "6/12 · RPS"

  local iface
  iface="$(detect_iface)"
  iface="${iface:-eth0}"

  info "Основной интерфейс: $iface"

  cat >/usr/local/sbin/enable-rps.sh <<'EOF_RPS'
#!/usr/bin/env bash
set -e

IFACE="${1:-eth0}"

MASK="$(python3 - <<'PY'
import os

n = os.cpu_count() or 1
mask = (1 << n) - 1

parts = []
while mask:
    parts.append(f"{mask & 0xffffffff:x}")
    mask >>= 32

print(",".join(parts) if parts else "1")
PY
)"

echo "RPS iface: $IFACE"
echo "RPS mask: $MASK"

if [[ ! -d "/sys/class/net/$IFACE" ]]; then
  echo "Interface $IFACE not found"
  exit 0
fi

for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
  [[ -e "$q" ]] || continue
  echo "$MASK" > "$q" || true
done

for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_flow_cnt; do
  [[ -e "$q" ]] || continue
  echo 32768 > "$q" || true
done

echo 32768 > /proc/sys/net/core/rps_sock_flow_entries || true

cat /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus 2>/dev/null || true
EOF_RPS

  chmod +x /usr/local/sbin/enable-rps.sh

  cat >/etc/systemd/system/na-rps-lite.service <<EOF_SERVICE
[Unit]
Description=Enable RPS dynamically
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/enable-rps.sh $iface
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  run_cmd "Перезагружаю systemd" systemctl daemon-reload
  run_cmd "Включаю RPS" systemctl enable --now na-rps-lite.service

  ok "RPS настроен для $iface"
}

install_docker() {
  section "7/12 · Docker"

  if ! command -v docker >/dev/null 2>&1; then
    run_shell "Устанавливаю Docker" "curl -fsSL https://get.docker.com | sh"
  else
    ok "Docker уже установлен"
  fi

  mkdir -p /etc/docker

  cat >/etc/docker/daemon.json <<'EOF_DOCKER'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  },
  "registry-mirrors": [
    "https://mirror.gcr.io"
  ],
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 1048576,
      "Soft": 1048576
    }
  },
  "live-restore": true
}
EOF_DOCKER

  run_cmd "Включаю Docker" systemctl enable docker
  run_cmd "Перезапускаю Docker" systemctl restart docker

  local docker_v compose_v
  docker_v="$(docker --version 2>/dev/null || true)"
  compose_v="$(docker_compose_version_safe)"

  ok "${docker_v:-Docker установлен}"
  if [[ "$compose_v" == "Docker Compose не найден" ]]; then
    warn "$compose_v. Установка ноды потребует docker compose plugin или docker-compose."
  else
    ok "$compose_v"
  fi
}

disable_llmnr() {
  section "8/12 · Закрытие LLMNR / 5355"

  mkdir -p /etc/systemd/resolved.conf.d

  cat >/etc/systemd/resolved.conf.d/99-no-llmnr.conf <<'EOF_RESOLVED'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF_RESOLVED

  systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1 || true

  if ss -tulpen | grep -q 5355; then
    warn "5355 всё ещё слушается. Проверь systemd-resolved вручную."
  else
    ok "5355 закрыт"
  fi
}

run_final_test() {
  section "9/12 · Проверка системы"

  local kernel cc qdisc bbr_version thp_state docker_v compose_v
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  bbr_version="$(cat /sys/module/tcp_bbr/version 2>/dev/null || true)"
  thp_state="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"

  if command -v docker >/dev/null 2>&1; then
    docker_v="$(docker --version 2>/dev/null || echo 'Docker установлен, но не отвечает')"
  else
    docker_v="Docker не установлен"
  fi

  compose_v="$(docker_compose_version_safe)"

  {
    echo "uname -r:"
    uname -r 2>/dev/null || true

    echo
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss 2>/dev/null || true

    echo
    echo "BBR version:"
    cat /sys/module/tcp_bbr/version 2>/dev/null || true

    echo
    echo "THP:"
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

    echo
    echo "Docker:"
    if command -v docker >/dev/null 2>&1; then
      docker version 2>/dev/null || true
    else
      echo "Docker не установлен"
    fi

    echo
    echo "Docker Compose:"
    docker_compose_version_safe || true

    echo
    echo "Listening sockets:"
    if command -v ss >/dev/null 2>&1; then
      ss -tulpen 2>/dev/null || true
    else
      echo "ss не найден"
    fi
  } >> "$LOG_FILE" 2>&1 || true

  ok "Kernel: $kernel"
  ok "TCP CC: ${cc:-unknown}"
  ok "Qdisc: ${qdisc:-unknown}"
  ok "BBR module: ${bbr_version:-unknown}"

  if [[ "$docker_v" == "Docker не установлен" ]]; then
    warn "$docker_v"
  else
    ok "$docker_v"
  fi

  if [[ "$compose_v" == "Docker Compose не найден" ]]; then
    warn "$compose_v"
  else
    ok "$compose_v"
  fi

  if [[ -n "$thp_state" ]]; then
    ok "THP: $thp_state"
  else
    warn "THP status недоступен на этом ядре/окружении"
  fi
}

optional_speedtest() {
  section "10/12 · Speedtest"

  echo
  read -rp "  Запустить iperf3 speedtest сейчас? [y/N]: " ans

  case "${ans,,}" in
    y|yes|д|да)
      echo
      echo "${C_DIM}  TCP counters before:${C_RESET}"
      nstat -az TcpRetransSegs TcpOutSegs 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || true

      if run_shell_live "Запускаю iperf3 speedtest" \
        "bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)"; then
        :
      else
        warn "Speedtest завершился с ошибкой, но это не критично — продолжаю установку."
      fi

      echo
      echo "${C_DIM}  TCP counters after:${C_RESET}"
      nstat -az TcpRetransSegs TcpOutSegs 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || true
      ;;
    *)
      ok "Speedtest пропущен"
      ;;
  esac
}

optional_selfsteal() {
  section "11/12 · Selfsteal"

  echo
  read -rp "  Запустить selfsteal.sh сейчас? [y/N]: " ans

  case "${ans,,}" in
    y|yes|д|да)
      if run_shell_live "Запускаю selfsteal.sh" "bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh)"; then
        ok "Selfsteal завершён, продолжаю установку ноды."
      else
        warn "Selfsteal.sh вернул ненулевой код (это может быть нормально для его собственной логики). Продолжаю установку ноды — её настройка дальше не зависит от selfsteal."
      fi
      ;;
    *)
      ok "Selfsteal пропущен"
      ;;
  esac
}

ask_domain() {
  local input=""

  while true; do
    read -rp "  Домен для сертификата (например, node.example.com): " input
    input="$(echo "${input:-}" | tr -d '[:space:]')"

    if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      DOMAIN="$input"
      ok "Домен: $DOMAIN"
      return 0
    fi

    warn "Некорректный домен. Пример: node.example.com"
  done
}

issue_tls_certificate() {
  section "11/12 · TLS сертификат"

  if ! command -v certbot >/dev/null 2>&1; then
    run_cmd "Устанавливаю certbot" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y certbot
  fi

  # Если скрипт запускают повторно (например, после сбоя запуска ноды) и для
  # ранее сохранённого домена уже есть действующий сертификат — не спрашиваем
  # заново и не выпускаем его повторно.
  if [[ -f "$DOMAIN_FILE" ]]; then
    local saved_domain
    saved_domain="$(cat "$DOMAIN_FILE" 2>/dev/null || true)"

    if [[ -n "$saved_domain" ]] && check_existing_certificate "$saved_domain"; then
      DOMAIN="$saved_domain"
      CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
      CERT_OK=1
      ok "Найден действующий сертификат для домена $DOMAIN. Повторный выпуск не требуется."
      return 0
    fi
  fi

  # Файла состояния с доменом нет (или он битый) — ищем на диске сертификаты,
  # выпущенные в прошлых запусках (в том числе более старой версией скрипта,
  # ещё не сохранявшей домен), и предлагаем переиспользовать вместо выпуска
  # нового.
  local found_certs found_count
  found_certs="$(find_existing_certificates)"
  found_count=0
  [[ -n "$found_certs" ]] && found_count="$(echo "$found_certs" | wc -l)"

  if [[ "$found_count" -gt 0 ]]; then
    echo
    info "На сервере уже есть действующие сертификаты Let's Encrypt:"
    echo "$found_certs" | sed 's/^/    - /'
    echo

    local reuse_ans reuse_domain
    read -rp "  Использовать один из них вместо выпуска нового? [Y/n]: " reuse_ans

    case "${reuse_ans,,}" in
      n|no|н|нет)
        ;;
      *)
        if [[ "$found_count" -eq 1 ]]; then
          reuse_domain="$found_certs"
        else
          read -rp "  Введи домен из списка выше: " reuse_domain
          reuse_domain="$(echo "${reuse_domain:-}" | tr -d '[:space:]')"
        fi

        if check_existing_certificate "$reuse_domain"; then
          DOMAIN="$reuse_domain"
          CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
          CERT_OK=1
          save_domain
          ok "Использую существующий сертификат: $CERT_DIR"
          return 0
        fi

        warn "Не удалось подтвердить сертификат для '$reuse_domain'. Перехожу к обычному выпуску."
        ;;
    esac
  fi

  echo
  info "Перед выпуском сертификата убедись, что A-запись домена указывает на IP этого сервера."
  info "Certbot (standalone) временно займёт порт 80 — он должен быть свободен."
  echo

  local attempt=1
  local max_attempts=3

  while true; do
    ask_domain

    if check_existing_certificate "$DOMAIN"; then
      CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
      CERT_OK=1
      save_domain
      ok "Найден действующий сертификат для домена $DOMAIN. Повторный выпуск не требуется."
      return 0
    fi

    run_shell "Освобождаю порт 80 (если занят nginx/apache)" \
      "systemctl stop nginx >/dev/null 2>&1 || true; systemctl stop apache2 >/dev/null 2>&1 || true; true"

    CERT_OK=0

    if run_cmd "Выпускаю сертификат Let's Encrypt для $DOMAIN" \
      certbot certonly --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email --preferred-challenges http \
      -d "$DOMAIN"; then

      if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
        CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
        CERT_OK=1
      fi
    fi

    if [[ "$CERT_OK" -eq 1 ]]; then
      ok "Сертификат успешно выпущен: $CERT_DIR"
      save_domain
      return 0
    fi

    fail "Не удалось выпустить сертификат для домена $DOMAIN."

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      warn "Достигнут лимит попыток ($max_attempts). Продолжаю установку ноды без TLS-сертификата."
      warn "Выпусти сертификат вручную позже (certbot certonly --standalone -d $DOMAIN) и пропиши пути в конфиге инбаундов панели."
      return 0
    fi

    echo
    read -rp "  Попробовать снова с другим доменом? [Y/n]: " ans

    case "${ans,,}" in
      n|no|н|нет)
        warn "Продолжаю установку ноды без TLS-сертификата."
        return 0
        ;;
      *)
        attempt=$((attempt + 1))
        ;;
    esac
  done
}

# Диспетчер шага 11/12: REALITY — как раньше через selfsteal.sh,
# TLS — выпуск сертификата через certbot.
step_transport_setup() {
  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    issue_tls_certificate
  else
    optional_selfsteal
  fi
}

run_warp_setup() {
  section "Настройка WARP"
  info "Запускаю Eclipse WARP Manager (отдельный скрипт, своё меню)."
  info "Репозиторий: https://github.com/blantxxv/warp"
  echo

  if bash -c "bash <(curl -fsSL '$WARP_INSTALL_URL')"; then
    ok "Eclipse WARP Manager завершил работу."
  else
    warn "Eclipse WARP Manager завершился с ошибкой или был прерван. Подробности — в его собственном логе: /var/log/warp-auto-install.log"
  fi
}

is_torrent_blocker_installed() {
  [[ -x "$TORRENT_BLOCKER_BIN" ]]
}

install_torrent_blocker() {
  section "Torrent Blocker"

  if is_torrent_blocker_installed; then
    ok "Torrent Blocker уже установлен: $TORRENT_BLOCKER_BIN"
    info "Переустанавливаю: останавливаю сервис, удаляю бинарник, ставлю заново."

    run_shell "Останавливаю и удаляю старую версию Torrent Blocker" \
      "systemctl stop torrent-blocker >/dev/null 2>&1 || true; rm -f '$TORRENT_BLOCKER_BIN'"
  else
    info "Torrent Blocker не найден на сервере. Устанавливаю с нуля."
  fi

  if run_shell_live "Скачиваю и устанавливаю Torrent Blocker" \
    "curl -fsSL '$TORRENT_BLOCKER_INSTALL_URL' | bash"; then
    ok "Установка Torrent Blocker завершена."

    if systemctl is-active --quiet torrent-blocker 2>/dev/null; then
      ok "Сервис torrent-blocker активен."
    else
      warn "Сервис torrent-blocker не выглядит активным. Проверь: systemctl status torrent-blocker"
    fi
  else
    warn "Установка Torrent Blocker завершилась с ошибкой или была прервана. Смотри вывод выше."
  fi
}

sanitize_node_name() {
  local raw="$1"

  raw="${raw:-Unknown}"
  raw="$(echo "$raw" | tr -cd '[:alnum:] ._-' | sed -E 's/[[:space:]_]+/-/g; s/^-+//; s/-+$//')"

  if [[ -z "$raw" ]]; then
    raw="Unknown"
  fi

  echo "$raw"
}

sanitize_compose_name() {
  local raw="$1"

  raw="${raw:-remnanode}"
  raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

  if [[ -z "$raw" ]]; then
    raw="remnanode"
  fi

  echo "$raw"
}

detect_country_name() {
  local country=""

  country="$(curl -fsSL --connect-timeout 4 --max-time 8 https://ipapi.co/country_name/ 2>/dev/null | head -n 1 | tr -d '\r' || true)"

  if [[ -z "$country" || "$country" == "Undefined" || "$country" == "Reserved" ]]; then
    country="$(curl -fsSL --connect-timeout 4 --max-time 8 https://ifconfig.co/country 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  fi

  if [[ -z "$country" ]]; then
    country="Unknown"
  fi

  echo "$country"
}

detect_country_code() {
  local code=""

  code="$(curl -fsSL --connect-timeout 4 --max-time 8 https://ipapi.co/country/ 2>/dev/null | head -n 1 | tr -d '\r' | tr '[:lower:]' '[:upper:]' || true)"

  if [[ ! "$code" =~ ^[A-Z]{2}$ ]]; then
    code="$(curl -fsSL --connect-timeout 4 --max-time 8 https://ifconfig.co/country-iso 2>/dev/null | head -n 1 | tr -d '\r' | tr '[:lower:]' '[:upper:]' || true)"
  fi

  if [[ ! "$code" =~ ^[A-Z]{2}$ ]]; then
    code="XX"
  fi

  echo "$code"
}

ask_node_port() {
  local input=""
  local port_dec=""

  while true; do
    read -rp "  NODE_PORT [${DEFAULT_NODE_PORT}]: " input
    input="${input:-$DEFAULT_NODE_PORT}"

    if [[ "$input" =~ ^[0-9]{1,5}$ ]]; then
      port_dec="$((10#$input))"
      if (( port_dec >= 1 && port_dec <= 65535 )); then
        NODE_PORT="$port_dec"
        ok "Порт ноды: $NODE_PORT"
        return 0
      fi
    fi

    warn "Некорректный порт. Нужно число от 1 до 65535."
  done
}

prepare_node_paths() {
  local detected_country country_slug suffix base_dir compose_slug

  detected_country="$(detect_country_name)"
  country_slug="$(sanitize_node_name "$detected_country")"

  base_dir="/opt/${country_slug}-Node"

  if [[ -e "$base_dir" ]]; then
    suffix="$(tr -dc 'a-z0-9' </dev/urandom | head -c 4 || true)"
    suffix="${suffix:-$RANDOM}"
    REMNANODE_DIR="${base_dir}-${suffix}"
  else
    REMNANODE_DIR="$base_dir"
  fi

  NODE_DISPLAY_NAME="$(basename "$REMNANODE_DIR")"
  compose_slug="$(sanitize_compose_name "$NODE_DISPLAY_NAME")"

  COMPOSE_PROJECT_NAME="$compose_slug"
  CONTAINER_NAME="$compose_slug"
  REMNANODE_LOG_DIR="$REMNANODE_DIR/logs"

  ok "Страна сервера: $detected_country"
  ok "Папка ноды: $REMNANODE_DIR"
  ok "Папка логов: $REMNANODE_LOG_DIR"
  ok "Контейнер: $CONTAINER_NAME"
}

ask_tls_ports() {
  local input=""

  while true; do
    read -rp "  Порт VLESS+TCP+TLS [${DEFAULT_TLS_VLESS_PORT}]: " input
    input="${input:-$DEFAULT_TLS_VLESS_PORT}"

    if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      TLS_VLESS_PORT="$((10#$input))"
      break
    fi

    warn "Некорректный порт. Нужно число от 1 до 65535."
  done

  while true; do
    read -rp "  Порт Hysteria2 [${DEFAULT_HY2_PORT}]: " input
    input="${input:-$DEFAULT_HY2_PORT}"

    if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )) && [[ "$((10#$input))" -ne "$TLS_VLESS_PORT" ]]; then
      HY2_PORT="$((10#$input))"
      break
    fi

    warn "Некорректный порт (или совпадает с портом VLESS+TLS)."
  done

  ok "Порт VLESS+TLS: $TLS_VLESS_PORT"
  ok "Порт Hysteria2: $HY2_PORT"
}

# Генерирует готовый конфиг инбаундов для панели Remnawave: VLESS+TCP+TLS и
# Hysteria2 (salamander), с реальными путями к сертификатам, доменом,
# автосгенерированным паролем и автосгенерированными тегами.
generate_tls_panel_config() {
  section "Конфиг для панели"

  local country_code vless_tag hy2_tag hy2_password config_path

  country_code="$(detect_country_code)"
  vless_tag="VLESS_TCP_TLS_${country_code}_${TLS_VLESS_PORT}"
  hy2_tag="HYSTERIA2_SALAMANDER_${HY2_PORT}"
  hy2_password="$(openssl rand -base64 32)"
  config_path="$REMNANODE_DIR/panel-inbounds.json"

  cat > "$config_path" <<EOF_PANEL
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "$vless_tag",
      "port": $TLS_VLESS_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "http/1.1",
            "h2"
          ],
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "keyFile": "$CERT_DIR/privkey.pem",
              "certificateFile": "$CERT_DIR/fullchain.pem"
            }
          ]
        }
      }
    },
    {
      "tag": "$hy2_tag",
      "port": $HY2_PORT,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": {
        "users": [],
        "clients": [],
        "version": 2,
        "ignoreClientBandwidth": false
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "keyFile": "$CERT_DIR/privkey.pem",
              "certificateFile": "$CERT_DIR/fullchain.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "obfs": {
            "type": "salamander",
            "password": "$hy2_password"
          },
          "version": 2,
          "udpIdleTimeout": 60
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "domain": [
          "geosite:private"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-public-tracker"
        ],
        "ruleTag": "TORRENT_BY_DOMAIN",
        "outboundTag": "BLOCK"
      },
      {
        "port": "6881-6889,51413,21413,17417,37305",
        "type": "field",
        "ruleTag": "TORRENT_BY_PORT",
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOF_PANEL

  chmod 600 "$config_path"

  if command -v jq >/dev/null 2>&1; then
    if jq empty "$config_path" >/dev/null 2>&1; then
      ok "JSON конфиг валиден"
    else
      warn "JSON конфиг не прошёл проверку jq. Проверь файл вручную: $config_path"
    fi
  fi

  ok "Готовый конфиг инбаундов сохранён: $config_path"
  echo
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  cat "$config_path"
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  echo
  info "Скопируй JSON выше (или файл $config_path) в конфиг инбаундов ноды в панели Remnawave."
}

# Скачивает docker-образ с несколькими попытками, а при явном отказе Docker
# Hub (например, "403 Forbidden" от registry-1.docker.io — блокировка/лимит
# по IP) пробует публичные зеркала из DOCKER_HUB_MIRRORS и перетегирует
# образ обратно в исходное имя, чтобы docker compose не пытался качать его
# заново.
pull_docker_image_with_fallback() {
  local image="$1"
  local attempt mirror mirror_image

  for attempt in 1 2 3; do
    if run_cmd "Скачиваю образ $image (попытка $attempt/3)" docker pull "$image"; then
      return 0
    fi
    sleep 5
  done

  warn "Не удалось скачать $image напрямую с Docker Hub (docker.io). Пробую зеркала registry..."

  for mirror in "${DOCKER_HUB_MIRRORS[@]}"; do
    mirror_image="${mirror}/${image}"

    if run_cmd "Скачиваю образ через зеркало $mirror" docker pull "$mirror_image"; then
      if run_cmd "Перетегирую образ в $image" docker tag "$mirror_image" "$image"; then
        ok "Образ $image получен через зеркало $mirror"
        return 0
      fi
    fi
  done

  fail "Не удалось скачать образ $image ни напрямую, ни через зеркала."
  return 1
}

setup_remnanode() {
  section "12/12 · Remnawave Node"

  prepare_node_paths
  ask_node_port

  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    ask_tls_ports
  fi

  echo
  echo "  Вставь SECRET_KEY из панели Remnawave."
  echo "  Ввод скрытый, это нормально."
  read -rsp "  SECRET_KEY: " SECRET_KEY
  echo

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  cd "$REMNANODE_DIR"

  run_cmd "Скачиваю geosite.dat" \
    curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -o geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

  run_cmd "Скачиваю geoip.dat" \
    curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -o geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

  run_cmd "Скачиваю geosite_2.dat (RU rules)" \
    curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -o geosite_2.dat \
    "$RU_GEOSITE_URL"

  run_cmd "Скачиваю geoip_2.dat (RU rules)" \
    curl -fsSL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    -o geoip_2.dat \
    "$RU_GEOIP_URL"

  touch "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"

  cat > "$REMNANODE_DIR/.env" <<EOF_ENV
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF_ENV

  chmod 600 "$REMNANODE_DIR/.env"

  local cert_volume_line=""
  if [[ "$NODE_INSTALL_TYPE" == "tls" && "$CERT_OK" -eq 1 ]]; then
    cert_volume_line="      - /etc/letsencrypt:/etc/letsencrypt:ro"
  fi

  cat > "$REMNANODE_DIR/docker-compose.yml" <<EOF_COMPOSE
name: $COMPOSE_PROJECT_NAME

services:
  remnanode:
    container_name: $CONTAINER_NAME
    hostname: $CONTAINER_NAME
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - ./geosite.dat:/usr/local/share/xray/geosite.dat:ro
      - ./geoip.dat:/usr/local/share/xray/geoip.dat:ro
      - ./geosite_2.dat:/usr/local/share/xray/geosite_2.dat:ro
      - ./geoip_2.dat:/usr/local/share/xray/geoip_2.dat:ro
      - ./logs:/var/log/remnanode
${cert_volume_line}
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
EOF_COMPOSE

  if ! pull_docker_image_with_fallback "remnawave/node:latest"; then
    warn "Образ remnawave/node:latest не удалось скачать заранее. docker compose up всё равно попробует сам."
  fi

  local up_ok=0
  local up_attempt
  for up_attempt in 1 2 3; do
    if run_cmd "Запускаю Remnawave Node (попытка $up_attempt/3)" docker_compose up -d; then
      up_ok=1
      break
    fi
    warn "Не удалось запустить контейнер. Возможно, Docker Hub временно недоступен (403/лимит). Повтор через 10 секунд..."
    sleep 10
  done

  if [[ "$up_ok" -ne 1 ]]; then
    warn "Не удалось запустить ноду после нескольких попыток."
    warn "Проверь вручную: cd $REMNANODE_DIR && docker compose pull && docker compose up -d"
    warn "Если в логе ошибка вида '403 Forbidden' от registry-1.docker.io — это блокировка/лимит Docker Hub по IP сервера. В /etc/docker/daemon.json уже настроено зеркало registry-mirrors (mirror.gcr.io), но если и оно недоступно — попробуй docker pull через VPN/другой сервер и docker save/docker load."
  fi

  docker_compose ps >> "$LOG_FILE" 2>&1 || true
  docker_compose logs --tail=100 >> "$LOG_FILE" 2>&1 || true

  if command -v ss >/dev/null 2>&1 && ss -tulpen 2>/dev/null | awk -v port=":$NODE_PORT" '$0 ~ port {found=1} END{exit found ? 0 : 1}'; then
    ok "Порт $NODE_PORT слушается"
  else
    warn "Порт $NODE_PORT не слушается. Проверь: cd $REMNANODE_DIR && docker compose logs -f --tail=100"
  fi

  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    if [[ "$CERT_OK" -eq 1 ]]; then
      generate_tls_panel_config
    else
      warn "Сертификат не был выпущен — пропускаю генерацию готового конфига для панели."
      warn "Выпусти сертификат вручную и добавь TLS-инбаунды в панели самостоятельно."
    fi
  fi
}

cleanup_continue_hook() {
  rm -f "$PROFILE_HOOK"
  set_state "done"
}

stage_before_reboot() {
  need_root
  print_banner
  save_self

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  warn "Перед установкой ядра убедись, что у VPS есть VNC/Rescue-консоль на случай, если сервер не загрузится после reboot."

  echo
  read -rp "  Продолжить установку? [y/N]: " ans

  case "${ans,,}" in
    y|yes|д|да) ;;
    *) die "Отменено пользователем." ;;
  esac

  ask_node_install_type

  install_base_packages
  check_cpu_level
  install_xanmod_kernel
  maybe_reboot

  stage_after_reboot
}

stage_after_reboot() {
  need_root
  print_banner

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  load_install_type

  section "Продолжение установки после reboot"

  if ! uname -r | grep -q "$KERNEL_VER"; then
    warn "Сейчас загружено ядро: $(uname -r)"
    warn "Ожидалось: $KERNEL_VER"
    warn "Продолжаю настройку, но BBR v3 может быть недоступен."
  else
    ok "Загружено ядро: $(uname -r)"
  fi

  apply_network_tuning
  disable_thp
  enable_rps
  install_docker
  disable_llmnr
  run_final_test
  optional_speedtest
  step_transport_setup
  setup_remnanode
  cleanup_continue_hook

  echo
  echo "${C_GREEN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗"
  echo "║                         ГОТОВО                               ║"
  echo "╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo "  Лог установки: $LOG_FILE"
  echo
  echo "  Remnawave Node:"
  echo "    cd $REMNANODE_DIR"
  echo "    docker compose ps"
  echo "    docker compose logs -f --tail=100"
  echo

  if [[ "$NODE_INSTALL_TYPE" == "tls" && "$CERT_OK" -eq 1 ]]; then
    echo "  Конфиг инбаундов для панели:"
    echo "    $REMNANODE_DIR/panel-inbounds.json"
    echo
  fi
}

print_manual_mode() {
  print_banner

  cat <<EOF_MANUAL
${C_BOLD}Ручная установка${C_RESET}

Вариант без автоматического скрипта: выполняй команды из README по разделам.

README:
  https://github.com/blantxxv/bbr3

Основные этапы:
  1. Базовые пакеты
  2. Проверка CPU level
  3. Установка XanMod kernel
  4. Reboot
  5. BBR / сетевой тюнинг
  6. Docker
  7. Remnawave Node в папке по стране сервера
  8. Выбор порта и динамическое имя контейнера
  9. Финальная проверка

Быстро открыть README на сервере можно так:

  curl -fL https://raw.githubusercontent.com/blantxxv/bbr3/main/README.md | less

EOF_MANUAL
}

pause_menu() {
  echo
  read -rp "  Нажми Enter для возврата в меню..." _ || true
}

main_menu() {
  need_root

  while true; do
    print_banner
    notify_if_update_available || true

    echo "${C_BOLD}Главное меню:${C_RESET}"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Автоматическая установка BBR3 + Remnawave Node"
    echo "  ${C_CYAN}2${C_RESET}) Продолжить установку после reboot"
    echo "  ${C_CYAN}3${C_RESET}) Ручная установка: показать README/команды"
    echo "  ${C_CYAN}4${C_RESET}) Настройка WARP"
    echo "  ${C_CYAN}5${C_RESET}) Проверить/установить обновления скрипта"
    echo "  ${C_CYAN}6${C_RESET}) Проверить систему"
    echo "  ${C_CYAN}7${C_RESET}) Torrent Blocker (установить/переустановить)"
    echo "  ${C_YELLOW}0${C_RESET}) Выход"
    echo

    read -rp "  Выбор [1/2/3/4/5/6/7/0]: " choice || choice="0"

    case "${choice:-}" in
      1)
        stage_before_reboot
        pause_menu
        ;;
      2)
        stage_after_reboot
        pause_menu
        ;;
      3)
        print_manual_mode
        pause_menu
        ;;
      4)
        run_warp_setup
        pause_menu
        ;;
      5)
        check_for_updates
        pause_menu
        ;;
      6)
        run_final_test
        pause_menu
        ;;
      7)
        install_torrent_blocker
        pause_menu
        ;;
      0|q|Q|exit|quit)
        echo "Выход."
        exit 0
        ;;
      *)
        warn "Неверный выбор: ${choice:-empty}"
        sleep 1
        ;;
    esac
  done
}

case "${1:-}" in
  --continue|continue)
    stage_after_reboot
    ;;
  --auto|--install|install)
    stage_before_reboot
    ;;
  --manual|manual)
    print_manual_mode
    ;;
  --warp|warp)
    need_root
    run_warp_setup
    ;;
  --check-update|--update|update)
    need_root
    check_for_updates
    ;;
  --test|test)
    need_root
    run_final_test
    ;;
  --torrent-blocker|torrent-blocker)
    need_root
    install_torrent_blocker
    ;;
  --menu|menu|"")
    main_menu
    ;;
  --help|-h|help)
    print_banner
    cat <<EOF_HELP
Использование:
  $0                    открыть главное меню
  $0 --menu             открыть главное меню
  $0 --auto             автоматическая установка
  $0 --install          алиас для --auto
  $0 --continue         продолжить после reboot
  $0 --manual           показать ручной режим
  $0 --warp             запустить настройку WARP
  $0 --check-update     проверить обновления
  $0 --test             проверить систему
  $0 --torrent-blocker  установить/переустановить Torrent Blocker
EOF_HELP
    ;;
  *)
    print_banner
    warn "Неизвестный аргумент: ${1:-}"
    echo "  Используй --help для списка команд."
    exit 1
    ;;
esac
