#!/usr/bin/env bash

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")

SCRIPT_VERSION="3.0.0"

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

# XanMod ставим последней версией из официального APT-репозитория: метапакет
# linux-xanmod-x64vN сам тянет самый свежий образ ядра, поэтому фиксированные
# ссылки на .deb больше не нужны. KERNEL_VER заполняется реально установленной
# версией и сохраняется в state, чтобы после reboot знать, какое ядро ожидать.
KERNEL_VER=""
KERNEL_VER_FILE="$STATE_DIR/kernel_ver"
XANMOD_REPO_LIST="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_KEYRING="/usr/share/keyrings/xanmod-archive-keyring.gpg"

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

# Куда ставить ноду и все её файлы. Пользователь выбирает из готовых
# вариантов (/opt/remnanode, /home/<user>/remnanode, /root/remnanode) или
# вводит свой путь. Сохраняем реальный путь в state, чтобы пункты меню
# (обновление ядра xray и т.п.) знали, где лежит нода после перезапуска.
NODE_DIR_FILE="$STATE_DIR/node_dir"

# Параметры REALITY-инбаунда (TCP+REALITY). SNI — домен selfsteal/Caddy,
# target — локальный порт, куда REALITY проксирует «легитимный» трафик
# (по умолчанию 127.0.0.1:9443, как поднимает selfsteal). shortId и ключи
# x25519 генерируются на самом сервере.
DEFAULT_REALITY_PORT="443"
DEFAULT_REALITY_TARGET_PORT="9443"
REALITY_PORT=""
REALITY_SNI=""
REALITY_TARGET_PORT=""

# Репозиторий ядра Xray-core (для пункта меню «Обновление ядра xray»).
# Имя ассета (zip) выбирается по архитектуре в xray_asset_for_arch.
XRAY_CORE_REPO="XTLS/Xray-core"

# Куда ставить wrapper-команду для быстрого запуска (eclipse).
ECLIPSE_CMD="/usr/local/bin/eclipse"

# Случайный суффикс для тегов инбаундов (схема: протокол+порт+рандом), чтобы
# имена были уникальными между нодами и их не приходилось править руками.
# Заполняется один раз при установке ноды.
TAG_SUFFIX=""

# Строка монтирования кастомного ядра Xray в docker-compose (пусто = ядро,
# встроенное в образ remnawave/node). Заполняется, если при установке выбрали
# конкретную версию ядра.
XRAY_VOLUME_LINE=""

# Тип установки: "reality" (TCP+REALITY, как раньше) или "tls" (TCP+TLS со своим доменом)
NODE_INSTALL_TYPE=""
INSTALL_TYPE_FILE="$STATE_DIR/install_type"

DOMAIN=""
CERT_DIR=""
CERT_OK=0
DOMAIN_FILE="$STATE_DIR/domain"

# Опциональный Hysteria2 (UDP) inbound поверх REALITY-установки. Hysteria2
# всегда использует настоящий TLS (не Reality-маскировку), поэтому даже в
# REALITY-режиме для него нужен отдельный домен + сертификат Let's Encrypt.
HYSTERIA2_ENABLED=0

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

save_node_dir() {
  mkdir -p "$STATE_DIR"
  echo "$REMNANODE_DIR" > "$NODE_DIR_FILE"
}

# Определяет каталог установленной ноды. Сначала пробует сохранённый в state
# путь, затем ищет docker-compose.yml с образом remnawave/node в типичных
# местах. Нужно для пунктов меню, которые работают с уже установленной нодой
# (например, обновление ядра xray) — там REMNANODE_DIR ещё не заполнен.
find_node_dir() {
  local saved d

  if [[ -f "$NODE_DIR_FILE" ]]; then
    saved="$(cat "$NODE_DIR_FILE" 2>/dev/null || true)"
    if [[ -n "$saved" && -f "$saved/docker-compose.yml" ]]; then
      echo "$saved"
      return 0
    fi
  fi

  for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
    [[ -f "$d/docker-compose.yml" ]] || continue
    if grep -q 'remnawave/node' "$d/docker-compose.yml" 2>/dev/null; then
      echo "$d"
      return 0
    fi
  done

  return 1
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
  ip route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# Определяет, что скрипт выполняется внутри контейнера (LXC/OpenVZ/Docker),
# а не на железном/полноценном виртуальном сервере со своим ядром. Внутри
# контейнера ядро общее с хостом Proxmox: свой kernel-пакет ставить нельзя,
# и часть sysctl/sysfs операций сети недоступна из-за ограничений
# namespace/capabilities контейнера — это не сбой, а особенность окружения.
is_container_env() {
  # OpenVZ
  [[ -f /proc/user_beancounters ]] && return 0

  # systemd умеет определять контейнер напрямую (в т.ч. lxc на Proxmox)
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt="$(systemd-detect-virt --container 2>/dev/null || true)"
    [[ -n "$virt" && "$virt" != "none" ]] && return 0
  fi

  # Переменная окружения container=, которую проставляет lxc-init/liblxc
  if [[ -r /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then
    return 0
  fi

  # cgroup-путь процесса 1 внутри lxc/docker обычно содержит имя движка
  if grep -qaE '(lxc|docker|containerd)' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi

  return 1
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

# Возвращает самую свежую установленную версию ядра XanMod (строку uname -r),
# например 6.19.14-x64v3-xanmod1. Пусто, если XanMod-ядро не установлено.
highest_installed_xanmod() {
  dpkg-query -W -f='${Package}\n' 'linux-image-*xanmod*' 2>/dev/null \
    | sed 's/^linux-image-//' \
    | grep -E 'xanmod' \
    | sort -V \
    | tail -n1
}

# Загружает ожидаемую версию XanMod-ядра из state (нужно после reboot).
load_kernel_ver() {
  if [[ -z "$KERNEL_VER" && -f "$KERNEL_VER_FILE" ]]; then
    KERNEL_VER="$(cat "$KERNEL_VER_FILE" 2>/dev/null || true)"
  fi
}

# Подключает официальный APT-репозиторий XanMod (deb.xanmod.org). Возвращает 0
# при успехе. Метапакеты linux-xanmod-x64vN из него всегда тянут самую свежую
# версию ядра.
setup_xanmod_repo() {
  if [[ -z "${OS_ID:-}" || "$OS_ID" == "unknown" ]]; then
    detect_os_info
  fi

  run_cmd "Ставлю зависимости репозитория XanMod" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg curl ca-certificates || return 1

  if ! run_shell "Добавляю GPG-ключ XanMod" \
    "set -o pipefail; curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o '$XANMOD_KEYRING'"; then
    return 1
  fi

  echo "deb [signed-by=$XANMOD_KEYRING] http://deb.xanmod.org releases main" > "$XANMOD_REPO_LIST"

  run_cmd "Обновляю APT index (XanMod repo)" \
    env DEBIAN_FRONTEND=noninteractive apt-get update || return 1

  return 0
}

install_xanmod_kernel() {
  section "3/12 · XanMod kernel (последняя версия)"

  if is_container_env; then
    KERNEL_INSTALL_SKIPPED=1
    warn "Обнаружено контейнерное окружение (LXC/OpenVZ) — ядро общее с хостом Proxmox, свой kernel-пакет здесь ставить нельзя и не нужно."
    info "Пропускаю установку XanMod и связанный с ней reboot. Сетевой тюнинг всё равно применится там, где это разрешено ядром хоста и правами контейнера."
    return 0
  fi

  local meta
  case "$CPU_LEVEL" in
    v4|v3) meta="linux-xanmod-x64v3" ;;
    v2)    meta="linux-xanmod-x64v2" ;;
    *)
      KERNEL_INSTALL_SKIPPED=1
      warn "Пропускаю установку XanMod: CPU level ${CPU_LEVEL:-unknown} ниже v2 (XanMod требует минимум x64v2)."
      info "Сервер останется на текущем ядре, сетевой тюнинг всё равно применится там, где это поддерживается."
      return 0
      ;;
  esac

  KERNEL_INSTALL_SKIPPED=0

  if ! setup_xanmod_repo; then
    KERNEL_INSTALL_SKIPPED=1
    warn "Не удалось подключить репозиторий XanMod — пропускаю установку ядра, продолжаю без него."
    return 0
  fi

  info "Ставлю метапакет $meta (тянет самую свежую версию ядра XanMod)."

  if ! run_cmd "Устанавливаю XanMod kernel ($meta)" \
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$meta"; then
    KERNEL_INSTALL_SKIPPED=1
    warn "Не удалось установить $meta — продолжаю без нового ядра."
    return 0
  fi

  KERNEL_VER="$(highest_installed_xanmod)"
  if [[ -n "$KERNEL_VER" ]]; then
    mkdir -p "$STATE_DIR"
    echo "$KERNEL_VER" > "$KERNEL_VER_FILE"
    ok "Установлена версия ядра XanMod: $KERNEL_VER"
  else
    warn "Не удалось определить установленную версию XanMod (dpkg-query пусто)."
  fi

  run_cmd "Обновляю GRUB" update-grub || warn "update-grub вернул ошибку — проверь загрузчик вручную."
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

  load_kernel_ver

  if [[ -n "$KERNEL_VER" ]]; then
    if [[ "$(uname -r)" == "$KERNEL_VER" ]]; then
      ok "Ребут не нужен, уже загружено ядро $KERNEL_VER"
      return 0
    fi
  elif uname -r | grep -q 'xanmod'; then
    ok "Ребут не нужен, уже загружено ядро XanMod: $(uname -r)"
    return 0
  fi

  set_state "need_post_reboot"
  install_profile_continue_hook

  echo
  echo "${C_YELLOW}${C_BOLD}Первый этап завершён. Сейчас будет reboot.${C_RESET}"
  echo "${C_DIM}После ребута зайди снова по SSH под root — скрипт сам продолжится и попросит SECRET_KEY.${C_RESET}"
  echo

  sleep 5
  reboot || warn "Команда reboot вернула ошибку (типично для среды без прав на перезагрузку хоста). Перезагрузи сервер вручную и запусти скрипт с --continue."
}

apply_network_tuning() {
  section "4/12 · Сетевой тюнинг"

  if is_container_env; then
    info "Обнаружено контейнерное окружение (LXC/OpenVZ) — часть sysctl-параметров (net./vm./fs.) может быть недоступна для записи из контейнера: 'Operation not permitted' или 'Read-only file system'. Это ожидаемо, не ошибка установки — скрипт применит то, что разрешено правами контейнера, и пропустит остальное."
  fi

  modprobe tcp_bbr >> "$LOG_FILE" 2>&1 || warn "Не удалось загрузить модуль tcp_bbr (ожидаемо в контейнере без CAP_SYS_MODULE) — продолжаю."

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

  # sysctl --system всегда возвращает ненулевой код, если хотя бы один ключ
  # не применился (типично для LXC — часть net./vm./fs. параметров read-only).
  # Не используем run_cmd, чтобы при этом не сыпать в терминал полный дамп
  # лога через show_last_log — это ожидаемый сценарий, а не сбой установки.
  local sysctl_out sysctl_rc skipped_count
  set +e
  sysctl_out="$(sysctl --system 2>&1)"
  sysctl_rc=$?
  set -e
  log_line "sysctl --system output:"
  log_line "$sysctl_out"

  if [[ "$sysctl_rc" -eq 0 ]]; then
    ok "sysctl параметры применены"
  else
    skipped_count="$(grep -c '^sysctl: setting key' <<< "$sysctl_out" || true)"
    warn "sysctl: пропущено параметров: ${skipped_count:-?} (недоступны в этом окружении). Подробности: $LOG_FILE"
  fi

  local cc qdisc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  if [[ -n "$cc" ]]; then
    ok "TCP congestion control: $cc"
  else
    warn "TCP congestion control: не удалось определить"
  fi

  if [[ -n "$qdisc" ]]; then
    ok "Default qdisc: $qdisc"
  else
    warn "Default qdisc: не удалось определить"
  fi
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

  run_cmd "Включаю disable-thp.service" systemctl daemon-reload \
    || warn "systemctl daemon-reload вернул ошибку (типично для ограниченного контейнера) — продолжаю."
  run_cmd "Отключаю THP" systemctl enable --now disable-thp.service \
    || warn "Не удалось включить disable-thp.service (типично для контейнера без доступа к /sys/kernel/mm) — продолжаю."

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

  run_cmd "Перезагружаю systemd" systemctl daemon-reload \
    || warn "systemctl daemon-reload вернул ошибку (типично для ограниченного контейнера) — продолжаю."
  run_cmd "Включаю RPS" systemctl enable --now na-rps-lite.service \
    || warn "Не удалось включить na-rps-lite.service (типично для контейнера без доступа к /sys/class/net/*/queues) — продолжаю."

  ok "RPS настроен для $iface"
}

# Подключает официальный APT-репозиторий Docker (download.docker.com) вручную:
# GPG-ключ + docker.list с правильным дистрибутивом/codename/архитектурой.
# Используется как запасной путь, когда convenience-скрипт get.docker.com
# недоступен (например, отдаёт 403 по IP сервера). Возвращает 0 при успехе.
setup_docker_official_repo() {
  local distro codename arch

  # После reboot detect_os_info в этой стадии ещё не вызывался — заполняем OS_*.
  if [[ -z "${OS_ID:-}" || "$OS_ID" == "unknown" ]]; then
    detect_os_info
  fi

  distro="$OS_ID"
  codename="$OS_CODENAME"

  if [[ "$distro" != "ubuntu" && "$distro" != "debian" ]]; then
    warn "Официальный репозиторий Docker поддерживает только Ubuntu/Debian (тут: ${distro:-unknown}). Пропускаю этот способ."
    return 1
  fi

  if [[ -z "$codename" || "$codename" == "unknown" ]]; then
    warn "Не удалось определить codename дистрибутива для репозитория Docker."
    return 1
  fi

  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

  run_cmd "Ставлю зависимости репозитория Docker" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg || return 1

  install -m 0755 -d /etc/apt/keyrings || return 1

  run_cmd "Скачиваю GPG-ключ Docker" \
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable" \
    > /etc/apt/sources.list.d/docker.list

  run_cmd "Обновляю APT index (Docker repo)" \
    env DEBIAN_FRONTEND=noninteractive apt-get update || return 1

  return 0
}

# Ставит пакеты Docker CE из подключённого официального репозитория Docker.
install_docker_ce_packages() {
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  local avail=() p

  while IFS= read -r p; do
    [[ -n "$p" ]] && avail+=("$p")
  done < <(filter_available_packages "${pkgs[@]}")

  [[ "${#avail[@]}" -gt 0 ]] || return 1

  run_cmd "Устанавливаю Docker CE" \
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${avail[@]}"
}

# Последний запасной путь: docker.io + compose из репозитория самого
# дистрибутива (когда и download.docker.com недоступен). Даёт рабочий
# `docker` и `docker compose`/`docker-compose`.
install_docker_distro() {
  local pkgs=(docker.io docker-compose-v2 docker-compose-plugin docker-compose)
  local avail=() p have_docker_io=0

  run_cmd "Обновляю APT index" \
    env DEBIAN_FRONTEND=noninteractive apt-get update || true

  while IFS= read -r p; do
    [[ -n "$p" ]] && avail+=("$p")
    [[ "$p" == "docker.io" ]] && have_docker_io=1
  done < <(filter_available_packages "${pkgs[@]}")

  if [[ "$have_docker_io" -ne 1 ]]; then
    warn "Пакет docker.io недоступен в репозиториях дистрибутива."
    return 1
  fi

  run_cmd "Устанавливаю docker.io из репозитория дистрибутива" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y "${avail[@]}"
}

# Каскад установки движка Docker с корректной обработкой ошибок пайпа.
install_docker_engine() {
  # 1) Официальный convenience-скрипт. pipefail обязателен: без него код
  #    возврата берётся от `sh`, который при пустом stdin (curl отдал 403 и
  #    ничего не вывел) завершается успешно — и ошибка curl проглатывается.
  if run_shell "Устанавливаю Docker (get.docker.com)" \
    "set -o pipefail; curl -fsSL https://get.docker.com | sh" \
    && command -v docker >/dev/null 2>&1; then
    return 0
  fi

  warn "get.docker.com недоступен или вернул ошибку (частый случай — 403 по IP/региону сервера). Пробую официальный APT-репозиторий Docker напрямую."

  if setup_docker_official_repo && install_docker_ce_packages && command -v docker >/dev/null 2>&1; then
    ok "Docker установлен из официального репозитория Docker."
    return 0
  fi

  warn "Официальный репозиторий Docker не сработал. Пробую docker.io из репозитория дистрибутива."

  if install_docker_distro && command -v docker >/dev/null 2>&1; then
    ok "Docker установлен из репозитория дистрибутива (docker.io)."
    return 0
  fi

  die "Docker установить не удалось ни одним способом (get.docker.com, официальный репозиторий, docker.io)."
}

install_docker() {
  section "7/12 · Docker"

  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен"
  else
    install_docker_engine
  fi

  mkdir -p /etc/docker

  # В LXC-контейнере ulimit -Hn/-Hu ограничены потолком родительского
  # контейнера — фиксированные 1048576 как default-ulimits дают "operation
  # not permitted" при старте ЛЮБОГО контейнера без явных своих ulimits.
  # Берём реально достижимый потолок этого окружения (на bare metal/VM он
  # обычно и есть 1048576+, так что поведение там не меняется).
  local docker_nofile_limit docker_nproc_limit
  docker_nofile_limit="$(ulimit -Hn 2>/dev/null || true)"
  [[ "$docker_nofile_limit" =~ ^[0-9]+$ ]] || docker_nofile_limit=1048576
  (( docker_nofile_limit > 1048576 )) && docker_nofile_limit=1048576

  docker_nproc_limit="$(ulimit -Hu 2>/dev/null || true)"
  [[ "$docker_nproc_limit" =~ ^[0-9]+$ ]] || docker_nproc_limit=1048576
  (( docker_nproc_limit > 1048576 )) && docker_nproc_limit=1048576

  cat >/etc/docker/daemon.json <<EOF_DOCKER
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
      "Hard": $docker_nofile_limit,
      "Soft": $docker_nofile_limit
    },
    "nproc": {
      "Name": "nproc",
      "Hard": $docker_nproc_limit,
      "Soft": $docker_nproc_limit
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

  if [[ -n "$cc" ]]; then
    ok "TCP CC: $cc"
  else
    warn "TCP CC: не удалось определить"
  fi

  if [[ -n "$qdisc" ]]; then
    ok "Qdisc: $qdisc"
  else
    warn "Qdisc: не удалось определить"
  fi

  if [[ -n "$bbr_version" ]]; then
    ok "BBR module: $bbr_version"
  else
    warn "BBR module: не загружен (типично для LXC-контейнера без CAP_SYS_MODULE)"
  fi

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

run_iperf3_ru_speedtest() {
  echo
  echo "${C_DIM}  TCP counters before:${C_RESET}"
  nstat -az TcpRetransSegs TcpOutSegs 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || true

  if ! run_shell_live "Запускаю iperf3 speedtest (RU)" \
    "bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)"; then
    warn "iperf3 speedtest завершился с ошибкой, но это не критично — продолжаю."
  fi

  echo
  echo "${C_DIM}  TCP counters after:${C_RESET}"
  nstat -az TcpRetransSegs TcpOutSegs 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || true
}

optional_speedtest() {
  section "10/12 · Speedtest"

  echo
  echo "  Что запустить?"
  echo "  ${C_GREEN}1${C_RESET}) iperf3 (серверы в России)"
  echo "  ${C_GREEN}2${C_RESET}) Ookla Speedtest (ближайший мировой сервер)"
  echo "  ${C_GREEN}3${C_RESET}) Оба"
  echo "  ${C_YELLOW}0${C_RESET}) Пропустить"
  echo

  local ans
  read -rp "  Выбор [1/2/3/0]: " ans

  case "${ans:-0}" in
    1) run_iperf3_ru_speedtest ;;
    2) run_ookla_speedtest || true ;;
    3) run_iperf3_ru_speedtest; run_ookla_speedtest || true ;;
    *) ok "Speedtest пропущен" ;;
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

ask_enable_hysteria2() {
  echo
  read -rp "  Добавить Hysteria2 (UDP) inbound к этой ноде? [y/N]: " ans

  case "${ans,,}" in
    y|yes|д|да)
      HYSTERIA2_ENABLED=1
      ok "Hysteria2 будет добавлен."
      info "Hysteria2 использует настоящий TLS (не Reality-маскировку) — потребуется отдельный домен и сертификат Let's Encrypt."
      ;;
    *)
      HYSTERIA2_ENABLED=0
      ok "Hysteria2 пропущен."
      ;;
  esac
}

# Диспетчер шага 11/12: REALITY — как раньше через selfsteal.sh (+ опционально
# Hysteria2 поверх), TLS — выпуск сертификата через certbot.
step_transport_setup() {
  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    issue_tls_certificate
  else
    optional_selfsteal
    ask_enable_hysteria2

    if [[ "$HYSTERIA2_ENABLED" -eq 1 ]]; then
      issue_tls_certificate
    fi
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

# Короткий случайный суффикс (4 символа a-z0-9) для уникальности тегов.
gen_tag_suffix() {
  local s
  s="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 4 || true)"
  [[ -n "$s" ]] || s="$(printf '%04x' "$((RANDOM % 65536))")"
  echo "$s"
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

# Спрашивает, куда установить ноду и все её файлы. Варианты — готовые пути
# (/opt/remnanode, /home/<user>/remnanode, /root/remnanode) или свой путь.
# Заполняет REMNANODE_DIR.
ask_node_location() {
  section "Расположение ноды"

  echo
  echo "  Куда установить ноду и все её файлы?"
  echo
  echo "  ${C_GREEN}1${C_RESET}) /opt/remnanode          ${C_DIM}(рекомендуется)${C_RESET}"
  echo "  ${C_GREEN}2${C_RESET}) /home/<пользователь>/remnanode"
  echo "  ${C_GREEN}3${C_RESET}) /root/remnanode"
  echo "  ${C_GREEN}4${C_RESET}) Свой путь"
  echo

  local choice user_input path_input
  while true; do
    read -rp "  Выбор [1/2/3/4]: " choice

    case "${choice:-1}" in
      1)
        REMNANODE_DIR="/opt/remnanode"
        break
        ;;
      2)
        while true; do
          read -rp "  Имя пользователя (папка в /home): " user_input
          user_input="$(echo "${user_input:-}" | tr -d '[:space:]')"
          if [[ -n "$user_input" && "$user_input" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            REMNANODE_DIR="/home/$user_input/remnanode"
            [[ -d "/home/$user_input" ]] || warn "Каталог /home/$user_input не существует — будет создан."
            break
          fi
          warn "Некорректное имя пользователя."
        done
        break
        ;;
      3)
        REMNANODE_DIR="/root/remnanode"
        break
        ;;
      4)
        while true; do
          read -rp "  Абсолютный путь установки: " path_input
          path_input="$(echo "${path_input:-}" | tr -d '[:space:]')"
          if [[ "$path_input" == /* ]]; then
            REMNANODE_DIR="$path_input"
            break
          fi
          warn "Путь должен быть абсолютным (начинаться с /)."
        done
        break
        ;;
      *)
        warn "Некорректный выбор. Введи 1, 2, 3 или 4."
        ;;
    esac
  done

  ok "Папка ноды: $REMNANODE_DIR"
}

prepare_node_paths() {
  local name_input compose_slug

  ask_node_location

  if [[ -e "$REMNANODE_DIR" && -f "$REMNANODE_DIR/docker-compose.yml" ]]; then
    warn "В $REMNANODE_DIR уже есть установка ноды (docker-compose.yml). Файлы будут перезаписаны."
  fi

  echo
  echo "  Имя ноды/контейнера (латиница, для docker). Пустое = remnanode."
  read -rp "  Имя ноды [remnanode]: " name_input
  name_input="${name_input:-remnanode}"

  NODE_DISPLAY_NAME="$(sanitize_node_name "$name_input")"
  compose_slug="$(sanitize_compose_name "$NODE_DISPLAY_NAME")"

  COMPOSE_PROJECT_NAME="$compose_slug"
  CONTAINER_NAME="$compose_slug"
  REMNANODE_LOG_DIR="$REMNANODE_DIR/logs"

  ok "Папка логов: $REMNANODE_LOG_DIR"
  ok "Контейнер: $CONTAINER_NAME"
}

# TCP и UDP — независимые пространства портов ядра: сервис на TCP:443 и
# сервис на UDP:443 не конфликтуют. Поэтому здесь намеренно нет проверки
# "порт Hysteria2 не должен совпадать с портом VLESS+TLS" — совпадение
# номера порта совершенно нормально (именно так делает Reality+Hysteria2
# на 443 в примере пользователя).
ask_hysteria2_port() {
  local input=""

  while true; do
    read -rp "  Порт Hysteria2 (UDP) [${DEFAULT_HY2_PORT}]: " input
    input="${input:-$DEFAULT_HY2_PORT}"

    if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      HY2_PORT="$((10#$input))"
      break
    fi

    warn "Некорректный порт. Нужно число от 1 до 65535."
  done

  ok "Порт Hysteria2 (UDP): $HY2_PORT"
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

  ask_hysteria2_port

  if [[ "$HY2_PORT" -eq "$TLS_VLESS_PORT" ]]; then
    info "Hysteria2 (UDP) и VLESS+TLS (TCP) используют один и тот же номер порта $HY2_PORT — это нормально, TCP и UDP независимы."
  fi
}

# Генерирует готовый конфиг инбаундов для панели Remnawave: VLESS+TCP+TLS и
# Hysteria2 (salamander), с реальными путями к сертификатам, доменом,
# автосгенерированным паролем и автосгенерированными тегами.
generate_tls_panel_config() {
  section "Конфиг для панели"

  local vless_tag hy2_tag hy2_password config_path suffix

  suffix="${TAG_SUFFIX:-$(gen_tag_suffix)}"
  vless_tag="VLESS_TCP_TLS_${TLS_VLESS_PORT}_${suffix}"
  hy2_tag="HYSTERIA2_SALAMANDER_${HY2_PORT}_${suffix}"
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

# Генерирует Hysteria2-инбаунд (JSON-фрагмент) для REALITY-установок.
# Сам VLESS+REALITY inbound управляется отдельно (selfsteal.sh / вручную в
# панели), поэтому здесь только объект инбаунда Hysteria2 — его нужно
# добавить в массив "inbounds" существующего конфига ноды в панели, рядом
# с REALITY-инбаундом. Порт Hysteria2 (UDP) может совпадать по номеру с
# портом REALITY (TCP) — это разные протоколы, конфликта нет.
generate_hysteria2_panel_config() {
  section "Конфиг Hysteria2 для панели"

  local hy2_tag hy2_password config_path suffix

  suffix="${TAG_SUFFIX:-$(gen_tag_suffix)}"
  hy2_tag="HYSTERIA2_SALAMANDER_${HY2_PORT}_${suffix}"
  hy2_password="$(openssl rand -base64 32)"
  config_path="$REMNANODE_DIR/panel-inbound-hysteria2.json"

  cat > "$config_path" <<EOF_HY2
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
EOF_HY2

  chmod 600 "$config_path"

  if command -v jq >/dev/null 2>&1; then
    if jq empty "$config_path" >/dev/null 2>&1; then
      ok "JSON инбаунда Hysteria2 валиден"
    else
      warn "JSON инбаунда Hysteria2 не прошёл проверку jq. Проверь файл вручную: $config_path"
    fi
  fi

  ok "Готовый инбаунд Hysteria2 сохранён: $config_path"
  echo
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  cat "$config_path"
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  echo
  info "Добавь этот объект в массив \"inbounds\" конфига ноды в панели Remnawave — рядом с существующим VLESS+REALITY инбаундом."
  info "Порт $HY2_PORT/UDP (Hysteria2) может совпадать по номеру с портом REALITY по TCP — это независимые протоколы."
}

# Спрашивает параметры REALITY-инбаунда: порт (обычно 443), SNI (домен
# selfsteal/Caddy, он же попадёт в serverNames) и локальный target-порт,
# куда REALITY проксирует замаскированный трафик (selfsteal по умолчанию
# слушает 127.0.0.1:9443).
ask_reality_params() {
  local input=""

  section "Параметры REALITY"

  while true; do
    read -rp "  Порт VLESS+REALITY (TCP) [${DEFAULT_REALITY_PORT}]: " input
    input="${input:-$DEFAULT_REALITY_PORT}"
    if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      REALITY_PORT="$((10#$input))"
      break
    fi
    warn "Некорректный порт. Нужно число от 1 до 65535."
  done

  while true; do
    read -rp "  Домен selfsteal (serverName), например safeeclipse.ru: " input
    input="$(echo "${input:-}" | tr -d '[:space:]')"
    if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      REALITY_SNI="$input"
      break
    fi
    warn "Некорректный домен. Пример: safeeclipse.ru"
  done

  while true; do
    read -rp "  Локальный target-порт selfsteal (Caddy) [${DEFAULT_REALITY_TARGET_PORT}]: " input
    input="${input:-$DEFAULT_REALITY_TARGET_PORT}"
    if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      REALITY_TARGET_PORT="$((10#$input))"
      break
    fi
    warn "Некорректный порт. Нужно число от 1 до 65535."
  done

  ok "REALITY: порт $REALITY_PORT, SNI $REALITY_SNI, target 127.0.0.1:$REALITY_TARGET_PORT"
}

# Генерирует пару ключей x25519 для REALITY прямо на сервере, используя
# бинарник xray внутри образа remnawave/node (на хосте xray обычно нет).
# Печатает две строки: "private" и "public". Возвращает 1, если не удалось.
generate_reality_keys() {
  local out priv pub

  out="$(docker run --rm --entrypoint xray remnawave/node:latest x25519 2>/dev/null || true)"

  if [[ -z "$out" ]]; then
    out="$(docker run --rm remnawave/node:latest xray x25519 2>/dev/null || true)"
  fi

  [[ -n "$out" ]] || return 1

  # Разные версии xray печатают по-разному:
  #   "Private key: ..." / "Public key: ..."
  #   "PrivateKey: ..."   / "Password: ..." (публичный ключ)
  priv="$(echo "$out" | grep -iE 'private' | head -n1 | sed -E 's/.*[:=][[:space:]]*//' | tr -d '[:space:]')"
  pub="$(echo "$out" | grep -iE 'public|password' | head -n1 | sed -E 's/.*[:=][[:space:]]*//' | tr -d '[:space:]')"

  [[ -n "$priv" && -n "$pub" ]] || return 1

  echo "$priv"
  echo "$pub"
}

# Генерирует готовый конфиг инбаундов для REALITY-установки: VLESS+TCP+REALITY
# с автосгенерированными shortId и ключами x25519. serverNames/target берутся
# из ответов пользователя (selfsteal-домен и локальный порт Caddy).
generate_reality_panel_config() {
  section "Конфиг REALITY для панели"

  local short_id keys priv_key pub_key config_path suffix

  suffix="${TAG_SUFFIX:-$(gen_tag_suffix)}"
  short_id="$(openssl rand -hex 8)"

  keys="$(generate_reality_keys || true)"
  if [[ -n "$keys" ]]; then
    priv_key="$(echo "$keys" | sed -n '1p')"
    pub_key="$(echo "$keys" | sed -n '2p')"
    ok "Ключи x25519 сгенерированы на сервере (через образ remnawave/node)."
  else
    priv_key="PASTE_PRIVATE_KEY_HERE"
    pub_key="PASTE_PUBLIC_KEY_HERE"
    warn "Не удалось сгенерировать ключи x25519 через xray. Подставлены плейсхолдеры — сгенерируй ключи вручную (xray x25519) и впиши их."
  fi

  config_path="$REMNANODE_DIR/panel-inbounds.json"

  cat > "$config_path" <<EOF_REALITY
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "VLESS_REALITY_${REALITY_PORT}_${suffix}",
      "port": $REALITY_PORT,
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
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "127.0.0.1:$REALITY_TARGET_PORT",
          "shortIds": [
            "$short_id"
          ],
          "privateKey": "$priv_key",
          "serverNames": [
            "$REALITY_SNI"
          ]
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
EOF_REALITY

  chmod 600 "$config_path"

  if command -v jq >/dev/null 2>&1; then
    if jq empty "$config_path" >/dev/null 2>&1; then
      ok "JSON конфиг валиден"
    else
      warn "JSON конфиг не прошёл проверку jq. Проверь файл вручную: $config_path"
    fi
  fi

  ok "Готовый REALITY-конфиг инбаундов сохранён: $config_path"
  echo
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  cat "$config_path"
  echo "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  echo
  echo "  ${C_BOLD}Публичный ключ (publicKey) для клиента/панели:${C_RESET} $pub_key"
  echo "  ${C_BOLD}shortId:${C_RESET} $short_id"
  echo
  info "Скопируй JSON выше (или файл $config_path) в конфиг инбаундов ноды в панели Remnawave."
  info "publicKey и shortId укажи в настройках подключения клиента."
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

# Проверяет, слушается ли порт, с несколькими попытками. После
# `docker compose up -d` контейнер и xray внутри стартуют не мгновенно —
# порт может появиться через несколько секунд, поэтому раньше проверка
# ложно сообщала «порт не слушается». Матчим порт по границе (двоеточие +
# номер + пробел/конец), чтобы :2222 не срабатывал на :22220. Учитываем и
# TCP, и UDP (для Hysteria2). Возвращает 0, если порт занят.
wait_for_port() {
  local port="$1"
  local attempts="${2:-15}"
  local i

  command -v ss >/dev/null 2>&1 || return 0

  for (( i = 1; i <= attempts; i++ )); do
    if ss -tulnH 2>/dev/null | grep -qE "[:.]${port}([[:space:]]|$)"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

setup_remnanode() {
  section "12/12 · Remnawave Node"

  prepare_node_paths
  ask_node_port

  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    ask_tls_ports
  else
    ask_reality_params
    if [[ "$HYSTERIA2_ENABLED" -eq 1 ]]; then
      ask_hysteria2_port
    fi
  fi

  echo
  echo "  Вставь SECRET_KEY из панели Remnawave."
  echo "  Ввод скрытый, это нормально."
  read -rsp "  SECRET_KEY: " SECRET_KEY
  echo

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  save_node_dir
  cd "$REMNANODE_DIR"

  # Один суффикс на ноду — все её теги инбаундов будут уникальны между нодами.
  TAG_SUFFIX="$(gen_tag_suffix)"

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

  # Выбор ядра Xray до старта контейнера (может смонтировать своё ядро).
  setup_xray_core_for_install

  local cert_volume_line=""
  if [[ "$NODE_INSTALL_TYPE" == "tls" && "$CERT_OK" -eq 1 ]]; then
    cert_volume_line="      - /etc/letsencrypt:/etc/letsencrypt:ro"
  fi

  # runc не может поднять rlimit контейнера выше жёсткого потолка своего
  # родительского процесса ("operation not permitted", errno EPERM для
  # setrlimit). В LXC-контейнере этот потолок (ulimit -Hn) обычно намного
  # ниже 1048576, поэтому вместо фиксированного значения берём то, что
  # реально достижимо в этом окружении — на bare metal/полноценной VM
  # ulimit -Hn обычно и есть 1048576+, так что поведение не меняется.
  local nofile_limit
  nofile_limit="$(ulimit -Hn 2>/dev/null || true)"
  if [[ -z "$nofile_limit" || "$nofile_limit" == "unlimited" ]] || ! [[ "$nofile_limit" =~ ^[0-9]+$ ]]; then
    nofile_limit=1048576
  fi
  if (( nofile_limit > 1048576 )); then
    nofile_limit=1048576
  fi
  info "Лимит nofile для контейнера ноды: $nofile_limit (потолок этого окружения: $(ulimit -Hn 2>/dev/null || echo unknown))"

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
${XRAY_VOLUME_LINE}
    ulimits:
      nofile:
        soft: $nofile_limit
        hard: $nofile_limit
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

  if wait_for_port "$NODE_PORT" 15; then
    ok "Порт $NODE_PORT слушается"
  else
    warn "Порт $NODE_PORT пока не слушается (контейнер мог ещё стартовать). Проверь: cd $REMNANODE_DIR && docker compose logs -f --tail=100"
  fi

  if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
    if [[ "$CERT_OK" -eq 1 ]]; then
      generate_tls_panel_config
    else
      warn "Сертификат не был выпущен — пропускаю генерацию готового конфига для панели."
      warn "Выпусти сертификат вручную и добавь TLS-инбаунды в панели самостоятельно."
    fi
  elif [[ "$NODE_INSTALL_TYPE" == "reality" ]]; then
    generate_reality_panel_config

    if [[ "$HYSTERIA2_ENABLED" -eq 1 ]]; then
      if [[ "$CERT_OK" -eq 1 ]]; then
        generate_hysteria2_panel_config
      else
        warn "Сертификат для Hysteria2 не был выпущен — пропускаю генерацию инбаунда."
        warn "Выпусти сертификат вручную и добавь Hysteria2-инбаунд в панели самостоятельно."
      fi
    fi
  fi

  # Если UFW уже активен — открываем порты этой ноды, чтобы не потерять связь.
  if command -v ufw >/dev/null 2>&1 && ufw_is_active; then
    ufw_allow_if_active "${NODE_PORT}/tcp"
    if [[ "$NODE_INSTALL_TYPE" == "tls" ]]; then
      ufw_allow_if_active "${TLS_VLESS_PORT}/tcp"
      ufw_allow_if_active "${HY2_PORT}/udp"
    else
      ufw_allow_if_active "${REALITY_PORT}/tcp"
      [[ "$HYSTERIA2_ENABLED" -eq 1 ]] && ufw_allow_if_active "${HY2_PORT}/udp"
    fi
    ok "Порты ноды открыты в UFW."
  fi

  # Автопродление сертификата с рестартом ноды — только если сертификат есть.
  if [[ "$CERT_OK" -eq 1 ]]; then
    install_cert_renew_hook
  fi
}

cleanup_continue_hook() {
  rm -f "$PROFILE_HOOK"
  set_state "done"
}

# Возвращает JSON списка релизов Xray-core с GitHub API.
fetch_xray_releases_json() {
  curl -fsSL --connect-timeout 5 --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${XRAY_CORE_REPO}/releases?per_page=20" 2>/dev/null || true
}

# Возвращает текущую версию xray в контейнере ноды (строку версии), либо пусто.
detect_current_xray_version() {
  local svc="remnanode"

  docker_compose exec -T "$svc" xray version 2>/dev/null \
    | grep -ioE 'Xray[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}'
}

# Добавляет в docker-compose.yml монтирование локального бинарника xray в
# контейнер, если его там ещё нет. Кастомный xray кладём рядом с нодой и
# монтируем поверх штатного /usr/local/bin/xray внутри образа.
ensure_xray_volume_mounted() {
  local compose="$REMNANODE_DIR/docker-compose.yml"

  [[ -f "$compose" ]] || return 1

  if grep -q './xray:/usr/local/bin/xray' "$compose"; then
    return 0
  fi

  # Вставляем строку монтирования сразу после строки с логами (она есть
  # в любой нашей генерации compose).
  if grep -q '\./logs:/var/log/remnanode' "$compose"; then
    sed -i '/\.\/logs:\/var\/log\/remnanode/a\      - ./xray:/usr/local/bin/xray:ro' "$compose"
    return 0
  fi

  warn "Не нашёл якорную строку в docker-compose.yml для вставки монтирования xray. Добавь вручную: - ./xray:/usr/local/bin/xray:ro"
  return 1
}

# Показывает меню выбора версии ядра Xray и печатает выбранный тег в stdout
# (пусто = пропустить/оставить как есть). Всё меню и подсказки идут в stderr,
# чтобы не мешать захвату результата через $(...). $1="1" добавляет пункт
# «оставить встроенное в образ ядро» вместо «Отмена».
select_xray_version() {
  local allow_keep="${1:-0}"
  local releases_json stable_ver actual_ver choice target_ver input keep_label

  releases_json="$(fetch_xray_releases_json)"
  if [[ -z "$releases_json" ]]; then
    warn "Не удалось получить список релизов Xray с GitHub. Проверь сеть." >&2
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    actual_ver="$(echo "$releases_json" | jq -r '.[0].tag_name' 2>/dev/null || true)"
    stable_ver="$(echo "$releases_json" | jq -r '[.[] | select(.prerelease==false)][0].tag_name' 2>/dev/null || true)"
  else
    actual_ver="$(echo "$releases_json" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
    stable_ver="$actual_ver"
  fi

  [[ "$actual_ver" == "null" ]] && actual_ver=""
  [[ "$stable_ver" == "null" ]] && stable_ver=""

  if [[ -z "$actual_ver" && -z "$stable_ver" ]]; then
    warn "Не удалось определить версии релизов Xray." >&2
    return 1
  fi

  if [[ "$allow_keep" == "1" ]]; then
    keep_label="  ${C_GREEN}0${C_RESET}) Оставить ядро, встроенное в образ (по умолчанию)"
  else
    keep_label="  ${C_YELLOW}0${C_RESET}) Отмена"
  fi

  {
    echo
    echo "  Доступные версии ядра Xray:"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Стабильная: ${stable_ver:-неизвестно}"
    echo "  ${C_GREEN}2${C_RESET}) Актуальная (последний релиз, возможно pre-release): ${actual_ver:-неизвестно}"
    echo "  ${C_GREEN}3${C_RESET}) Ввести версию вручную (например, v1.8.24)"
    echo "$keep_label"
    echo
  } >&2

  while true; do
    read -rp "  Выбор [1/2/3/0]: " choice
    case "${choice:-}" in
      1) target_ver="$stable_ver"; break ;;
      2) target_ver="$actual_ver"; break ;;
      3)
        read -rp "  Тег версии (с v, например v1.8.24): " input
        input="$(echo "${input:-}" | tr -d '[:space:]')"
        if [[ "$input" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
          [[ "$input" == v* ]] || input="v$input"
          target_ver="$input"
          break
        fi
        warn "Некорректный тег версии." >&2
        ;;
      0) echo ""; return 0 ;;
      *) warn "Некорректный выбор." >&2 ;;
    esac
  done

  echo "$target_ver"
}

# Возвращает имя zip-ассета Xray-core под архитектуру этого сервера.
xray_asset_for_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  case "$arch" in
    amd64|x86_64)   echo "Xray-linux-64.zip" ;;
    arm64|aarch64)  echo "Xray-linux-arm64-v8a.zip" ;;
    armhf|armv7l)   echo "Xray-linux-arm32-v7a.zip" ;;
    *)              echo "Xray-linux-64.zip" ;;
  esac
}

# Сверяет SHA256 скачанного zip с контрольной суммой из .dgst-файла релиза.
# 0 — совпало; 1 — не совпало; 2 — проверить не удалось (нет .dgst/суммы),
# что не считаем фатальным (старые релизы могут не иметь .dgst).
verify_xray_checksum() {
  local zip="$1" dgst_url="$2" tmp_dgst expected actual

  tmp_dgst="${zip}.dgst"
  if ! curl -fsSL --retry 3 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG -o "$tmp_dgst" "$dgst_url" 2>/dev/null; then
    return 2
  fi

  expected="$(grep -ioE 'sha(2-)?256[^0-9a-f]*[0-9a-f]{64}' "$tmp_dgst" 2>/dev/null | grep -oiE '[0-9a-f]{64}' | head -n1 | tr 'A-F' 'a-f')"
  [[ -n "$expected" ]] || return 2

  actual="$(sha256sum "$zip" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')"
  [[ -n "$actual" ]] || return 2

  [[ "$expected" == "$actual" ]]
}

# Скачивает бинарник ядра Xray указанного тега (под архитектуру сервера),
# проверяет контрольную сумму и кладёт в <dest_dir>/xray (исполняемым).
# Возвращает 0 при успехе.
download_xray_core() {
  local tag="$1" dest_dir="$2"
  local asset url tmpdir rc

  asset="$(xray_asset_for_arch)"
  url="https://github.com/${XRAY_CORE_REPO}/releases/download/${tag}/${asset}"
  tmpdir="$(mktemp -d)"

  info "Архитектура сервера · ассет ядра: $asset"

  if ! run_cmd "Скачиваю Xray $tag" \
    curl -fL --retry 5 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG -o "$tmpdir/xray.zip" "$url"; then
    rm -rf "$tmpdir"
    warn "Не удалось скачать ядро Xray $tag ($asset). Проверь, что такой релиз/ассет существует."
    return 1
  fi

  set +e
  verify_xray_checksum "$tmpdir/xray.zip" "${url}.dgst"
  rc=$?
  set -e
  case "$rc" in
    0) ok "Контрольная сумма Xray проверена (SHA256)." ;;
    1)
      rm -rf "$tmpdir"
      warn "Контрольная сумма ядра Xray НЕ совпала — загрузка повреждена или подменена. Отменяю."
      return 1
      ;;
    *) warn "Не удалось проверить контрольную сумму (.dgst недоступен) — продолжаю без проверки." ;;
  esac

  if ! run_cmd "Распаковываю Xray" unzip -o "$tmpdir/xray.zip" -d "$tmpdir"; then
    rm -rf "$tmpdir"
    return 1
  fi

  if [[ ! -f "$tmpdir/xray" ]]; then
    rm -rf "$tmpdir"
    warn "В архиве не найден бинарник xray."
    return 1
  fi

  install -m 0755 "$tmpdir/xray" "$dest_dir/xray"
  rm -rf "$tmpdir"
  ok "Бинарник ядра сохранён: $dest_dir/xray"
}

# Спрашивает и (при выборе) скачивает конкретное ядро Xray в папку ноды ещё
# до первого запуска контейнера. «Оставить встроенное» — ничего не монтируем,
# нода берёт xray из образа. Заполняет XRAY_VOLUME_LINE для docker-compose.
setup_xray_core_for_install() {
  section "Ядро Xray для ноды"
  info "Можно поставить конкретную версию ядра Xray сразу, либо оставить встроенное в образ (обновишь позже пунктом меню «Обновление ядра Xray»)."

  XRAY_VOLUME_LINE=""

  local target_ver
  if ! target_ver="$(select_xray_version 1)"; then
    warn "Не удалось получить версии ядра — оставляю ядро, встроенное в образ."
    return 0
  fi

  if [[ -z "$target_ver" ]]; then
    ok "Оставляю ядро, встроенное в образ remnawave/node."
    return 0
  fi

  ok "Выбрана версия ядра: $target_ver"

  if download_xray_core "$target_ver" "$REMNANODE_DIR"; then
    XRAY_VOLUME_LINE="      - ./xray:/usr/local/bin/xray:ro"
  else
    warn "Не удалось скачать ядро $target_ver — нода запустится со встроенным в образ ядром."
  fi
}

update_xray_core() {
  section "Обновление ядра Xray"

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker не установлен — обновлять ядро негде."
    return 1
  fi

  local node_dir
  node_dir="$(find_node_dir || true)"

  if [[ -z "$node_dir" ]]; then
    warn "Не удалось найти установленную ноду (docker-compose.yml с remnawave/node)."
    info "Сначала установи ноду (пункт 1), затем обновляй ядро."
    return 1
  fi

  REMNANODE_DIR="$node_dir"
  cd "$REMNANODE_DIR"
  ok "Нода найдена: $REMNANODE_DIR"

  local current_ver
  current_ver="$(detect_current_xray_version || true)"
  if [[ -n "$current_ver" ]]; then
    ok "Текущая версия Xray в контейнере: $current_ver"
  else
    info "Текущую версию Xray определить не удалось (контейнер не запущен или xray недоступен) — продолжаю."
  fi

  local target_ver
  if ! target_ver="$(select_xray_version 0)"; then
    return 1
  fi

  if [[ -z "$target_ver" ]]; then
    ok "Отменено."
    return 0
  fi

  ok "Выбрана версия ядра: $target_ver"

  download_xray_core "$target_ver" "$REMNANODE_DIR" || return 1

  ensure_xray_volume_mounted || true

  # Останавливаем ноду и запускаем заново, чтобы контейнер подхватил
  # смонтированный бинарник ядра.
  run_cmd "Останавливаю ноду" docker_compose down || warn "docker compose down вернул ошибку — продолжаю."
  if ! run_cmd "Запускаю ноду с новым ядром" docker_compose up -d; then
    warn "Не удалось запустить ноду после обновления ядра. Проверь: cd $REMNANODE_DIR && docker compose logs -f --tail=100"
    return 1
  fi

  sleep 3
  local new_ver
  new_ver="$(detect_current_xray_version || true)"
  if [[ -n "$new_ver" ]]; then
    ok "Xray в контейнере после обновления: $new_ver"
  else
    info "Не удалось прочитать версию Xray после старта — дай контейнеру подняться и проверь: docker compose exec remnanode xray version"
  fi

  ok "Обновление ядра Xray завершено."
}

# Создаёт короткую команду `eclipse` для запуска менеджера. Если системной
# копии скрипта ещё нет — сохраняет туда текущий файл, затем делает симлинк.
ensure_eclipse_command() {
  if [[ ! -s "$SCRIPT_PATH" ]]; then
    local src
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -n "$src" && -f "$src" && -r "$src" ]]; then
      mkdir -p "$(dirname "$SCRIPT_PATH")"
      if cp -- "$src" "$SCRIPT_PATH" 2>/dev/null; then
        chmod 700 "$SCRIPT_PATH"
      fi
    fi
  fi

  [[ -s "$SCRIPT_PATH" ]] || return 0
  ln -sf "$SCRIPT_PATH" "$ECLIPSE_CMD" 2>/dev/null || true
}

# ── UFW / порты ──────────────────────────────────────────────────────────────

ensure_ufw() {
  command -v ufw >/dev/null 2>&1 && return 0
  run_cmd "Устанавливаю ufw" env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
}

ufw_is_active() {
  ufw status 2>/dev/null | grep -q "Status: active"
}

# Разрешает порт(ы) в ufw, только если он активен (иначе молча пропускаем,
# чтобы не «включать» фаервол неожиданно во время установки ноды).
ufw_allow_if_active() {
  local spec="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw_is_active || return 0
  ufw allow "$spec" >/dev/null 2>&1 || true
}

# По умолчанию всегда открыты 22 (SSH), 80 и 443 — SSH первым, чтобы не
# потерять доступ при включении фаервола.
apply_firewall_defaults() {
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
}

firewall_show() {
  echo
  if ufw_is_active; then
    ok "UFW активен. Открытые правила:"
    ufw status numbered 2>/dev/null | sed 's/^/  /'
  else
    warn "UFW сейчас неактивен (правила не применяются, пока не включишь)."
    ufw status 2>/dev/null | sed 's/^/  /' || true
  fi
}

valid_port_spec() {
  [[ "$1" =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] || return 1
  local num="${1%%/*}"
  (( 10#$num >= 1 && 10#$num <= 65535 ))
}

manage_firewall() {
  section "Настройка портов (UFW)"

  if ! ensure_ufw; then
    warn "Не удалось установить ufw."
    return 1
  fi

  info "По умолчанию всегда открыты порты 22 (SSH), 80 и 443."
  apply_firewall_defaults

  local choice port
  while true; do
    firewall_show
    echo
    echo "  ${C_GREEN}1${C_RESET}) Разрешить порт"
    echo "  ${C_GREEN}2${C_RESET}) Закрыть порт"
    echo "  ${C_GREEN}3${C_RESET}) Включить UFW"
    echo "  ${C_GREEN}4${C_RESET}) Выключить UFW"
    echo "  ${C_GREEN}5${C_RESET}) Обновить список открытых портов"
    echo "  ${C_YELLOW}0${C_RESET}) Назад"
    echo
    read -rp "  Выбор: " choice

    case "${choice:-}" in
      1)
        read -rp "  Порт (например 2222 или 2222/udp): " port
        port="$(echo "${port:-}" | tr -d '[:space:]')"
        if valid_port_spec "$port"; then
          if ufw allow "$port" >/dev/null 2>&1; then
            ok "Разрешён порт $port"
          else
            warn "Не удалось добавить правило для $port"
          fi
        else
          warn "Некорректный порт. Пример: 2222 или 2222/udp"
        fi
        ;;
      2)
        read -rp "  Порт для закрытия (например 2222 или 2222/udp): " port
        port="$(echo "${port:-}" | tr -d '[:space:]')"
        if [[ "$port" =~ ^(22|80|443)(/tcp)?$ ]]; then
          warn "Порт $port относится к базовым (22/80/443) — закрывать не рекомендую (можно потерять доступ)."
          read -rp "  Всё равно закрыть? [y/N]: " ans
          case "${ans,,}" in y|yes|д|да) ;; *) continue ;; esac
        fi
        if valid_port_spec "$port"; then
          ufw delete allow "$port" >/dev/null 2>&1 && ok "Правило allow $port удалено" \
            || warn "Правило для $port не найдено (или уже удалено)."
        else
          warn "Некорректный порт."
        fi
        ;;
      3)
        apply_firewall_defaults
        if ufw --force enable >/dev/null 2>&1; then
          ok "UFW включён (22/80/443 и добавленные порты открыты)."
        else
          warn "Не удалось включить UFW."
        fi
        ;;
      4)
        if ufw disable >/dev/null 2>&1; then
          ok "UFW выключен."
        else
          warn "Не удалось выключить UFW."
        fi
        ;;
      5) ;;
      0|"") break ;;
      *) warn "Некорректный выбор." ;;
    esac
  done
}

# Ставит deploy-hook certbot: после обновления сертификата Let's Encrypt
# перезапускает все ноды Remnawave, чтобы xray перечитал новый fullchain/privkey
# (иначе TLS/Hysteria2-нода тихо отвалится через ~90 дней). Также включает
# таймер автообновления certbot.
install_cert_renew_hook() {
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  local hook="$hook_dir/restart-remnanode.sh"

  mkdir -p "$hook_dir"

  cat > "$hook" <<'EOF_HOOK'
#!/usr/bin/env bash
# Перезапуск нод Remnawave после обновления сертификата Let's Encrypt.
set -e

restart_dir() {
  local d="$1"
  ( cd "$d" && { docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null; } ) || true
}

for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
  [ -f "$d/docker-compose.yml" ] || continue
  grep -q 'remnawave/node' "$d/docker-compose.yml" 2>/dev/null || continue
  restart_dir "$d"
done
EOF_HOOK

  chmod +x "$hook"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true

  ok "Deploy-hook автопродления сертификата установлен: $hook"
  info "После каждого обновления сертификата нода перезапустится автоматически."
}

# ── Ookla Speedtest ──────────────────────────────────────────────────────────

# Ставит официальный Ookla Speedtest CLI (пакет speedtest) через их
# packagecloud-репозиторий; при неудаче пробует speedtest-cli из дистрибутива.
ensure_ookla_speedtest() {
  command -v speedtest >/dev/null 2>&1 && return 0

  if [[ -z "${OS_ID:-}" || "$OS_ID" == "unknown" ]]; then
    detect_os_info
  fi

  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    run_shell "Подключаю репозиторий Ookla Speedtest" \
      "set -o pipefail; curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash" || true
    run_cmd "Устанавливаю Ookla speedtest" \
      env DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest >/dev/null 2>&1 || true
  fi

  command -v speedtest >/dev/null 2>&1 && return 0

  # Фолбэк — python-клиент speedtest-cli.
  run_cmd "Устанавливаю speedtest-cli (фолбэк)" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli >/dev/null 2>&1 || true

  command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1
}

run_ookla_speedtest() {
  if ! ensure_ookla_speedtest; then
    warn "Не удалось установить Ookla Speedtest CLI."
    return 1
  fi

  if command -v speedtest >/dev/null 2>&1; then
    # Официальный Ookla CLI — нужно принять лицензию/GDPR при первом запуске.
    run_shell_live "Ookla Speedtest (ближайший сервер)" \
      "speedtest --accept-license --accept-gdpr 2>/dev/null || speedtest"
  else
    run_shell_live "Speedtest (speedtest-cli)" "speedtest-cli"
  fi
}

stage_before_reboot() {
  need_root
  print_banner
  save_self
  ensure_eclipse_command

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
  ensure_eclipse_command

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  load_install_type
  load_kernel_ver

  section "Продолжение установки после reboot"

  if is_container_env; then
    ok "Контейнерное окружение (LXC/OpenVZ) — используется ядро хоста: $(uname -r). Своё XanMod-ядро здесь не ставится, это нормально."
  elif [[ -n "$KERNEL_VER" ]]; then
    if [[ "$(uname -r)" == "$KERNEL_VER" ]]; then
      ok "Загружено ядро: $(uname -r)"
    else
      warn "Сейчас загружено ядро: $(uname -r)"
      warn "Ожидалось: $KERNEL_VER"
      warn "Продолжаю настройку, но BBR v3 может быть недоступен."
    fi
  elif uname -r | grep -q 'xanmod'; then
    ok "Загружено ядро XanMod: $(uname -r)"
  else
    warn "Загружено не XanMod-ядро: $(uname -r). Продолжаю, но BBR v3 может быть недоступен."
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
  echo "  Менеджер снова открыть командой: ${C_BOLD}eclipse${C_RESET}"
  echo

  if [[ "$NODE_INSTALL_TYPE" == "tls" && "$CERT_OK" -eq 1 ]]; then
    echo "  Конфиг инбаундов для панели:"
    echo "    $REMNANODE_DIR/panel-inbounds.json"
    echo
  elif [[ "$NODE_INSTALL_TYPE" == "reality" ]]; then
    echo "  Конфиг инбаундов для панели:"
    echo "    $REMNANODE_DIR/panel-inbounds.json"
    echo
    if [[ "$HYSTERIA2_ENABLED" -eq 1 && "$CERT_OK" -eq 1 ]]; then
      echo "  Конфиг инбаунда Hysteria2 для панели:"
      echo "    $REMNANODE_DIR/panel-inbound-hysteria2.json"
      echo
    fi
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
  7. Remnawave Node в выбранной папке (/opt/remnanode, /home/<user>/remnanode, /root/remnanode)
  8. Выбор порта и имя контейнера
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
  ensure_eclipse_command

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
    echo "  ${C_CYAN}8${C_RESET}) Обновление ядра Xray"
    echo "  ${C_CYAN}9${C_RESET}) Настройка портов (UFW)"
    echo "  ${C_YELLOW}0${C_RESET}) Выход"
    echo

    read -rp "  Выбор [1/2/3/4/5/6/7/8/9/0]: " choice || choice="0"

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
      8)
        update_xray_core
        pause_menu
        ;;
      9)
        manage_firewall
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
  --xray-core|--update-xray|xray-core)
    need_root
    update_xray_core
    ;;
  --firewall|--ufw|firewall|ufw)
    need_root
    manage_firewall
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
  $0 --xray-core        обновить ядро Xray в контейнере ноды
  $0 --firewall         настройка портов (UFW)

После первой установки менеджер доступен короткой командой: eclipse
EOF_HELP
    ;;
  *)
    print_banner
    warn "Неизвестный аргумент: ${1:-}"
    echo "  Используй --help для списка команд."
    exit 1
    ;;
esac
