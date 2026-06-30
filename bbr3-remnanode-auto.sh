#!/usr/bin/env bash

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")

SCRIPT_VERSION="2.1.1"

STATE_DIR="/var/lib/bbr3-remnanode"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/bbr3-remnanode-install.log"
SCRIPT_PATH="/usr/local/sbin/bbr3-remnanode-install.sh"
PROFILE_HOOK="/etc/profile.d/bbr3-remnanode-continue.sh"

SELF_DOWNLOAD_URL="https://raw.githubusercontent.com/blantxxv/bbr3/main/bbr3-remnanode-auto.sh"
WARP_INSTALL_URL="https://raw.githubusercontent.com/blantxxv/warp/main/warp-auto-install.sh"

CPU_LEVEL=""
KERNEL_INSTALL_SKIPPED=0

KERNEL_VER="6.19.14-x64v3-xanmod1"
XANMOD_BASE_URL="https://sourceforge.net/projects/xanmod/files/releases/main/6.19.14-xanmod1/6.19.14-x64v3-xanmod1"
IMAGE_DEB_URL="$XANMOD_BASE_URL/linux-image-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"
HEADERS_DEB_URL="$XANMOD_BASE_URL/linux-headers-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"

DEFAULT_NODE_PORT="2222"
REMNANODE_DIR=""
REMNANODE_LOG_DIR=""
NODE_PORT=""
NODE_DISPLAY_NAME=""
COMPOSE_PROJECT_NAME=""
CONTAINER_NAME=""

DEBUG="${DEBUG:-0}"

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
  mkdir -p "$(dirname "$LOG_FILE")"
  echo -e "[$(date '+%F %T')] [WARN] $*" >> "$LOG_FILE"
  echo "${C_YELLOW}  [WARN]${C_RESET} $*"
}

fail() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo -e "[$(date '+%F %T')] [ERROR] $*" >> "$LOG_FILE"
  echo "${C_RED}  [FAIL]${C_RESET} $*"
}

die() {
  fail "$*"
  echo
  echo "${C_DIM}Подробный лог: $LOG_FILE${C_RESET}"
  exit 1
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo -e "[$(date '+%F %T')] $*" >> "$LOG_FILE"
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

detect_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "Docker Compose не найден. Нужен docker compose plugin или docker-compose."
  fi
}

download_self_latest() {
  local target="$1"
  local tmp

  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"

  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    -o "$tmp" \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)"

  if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
    rm -f "$tmp"
    die "Скачанный скрипт не прошёл bash -n. Обновление отменено."
  fi

  mv -f "$tmp" "$target"
  chmod 700 "$target"
}

ensure_saved_script_is_latest() {
  local current_src=""
  current_src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

  if run_cmd "Обновляю системную копию скрипта" download_self_latest "$SCRIPT_PATH"; then
    return 0
  fi

  if [[ -n "$current_src" && -r "$current_src" && "$current_src" != "$SCRIPT_PATH" ]]; then
    warn "GitHub недоступен. Сохраняю текущую локальную копию для продолжения после reboot."
    run_cmd "Сохраняю локальную копию скрипта" cp -- "$current_src" "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"
    return 0
  fi

  die "Не удалось подготовить актуальную системную копию скрипта."
}

save_self() {
  ensure_saved_script_is_latest
}

# Возвращает успех (0), если версия $1 строго новее версии $2.
version_gt() {
  local a="$1" b="$2"

  [[ "$a" == "$b" ]] && return 1

  local lower
  lower="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)"

  [[ "$lower" == "$b" ]]
}

fetch_remote_script() {
  curl -fsSL --connect-timeout 5 --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)" 2>/dev/null || true
}

extract_script_version() {
  echo "$1" | grep -m1 '^SCRIPT_VERSION=' | sed -E 's/^SCRIPT_VERSION="([^"]*)".*/\1/'
}

# Подчищает старые/временные копии скрипта, чтобы не было конфликта версий.
cleanup_old_script_copies() {
  rm -f "${SCRIPT_PATH}".tmp.* 2>/dev/null || true
  rm -f "${SCRIPT_PATH}".bak 2>/dev/null || true
}

update_self_and_restart() {
  local remote_content="$1"
  local tmp

  mkdir -p "$(dirname "$SCRIPT_PATH")"
  tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")"
  printf '%s\n' "$remote_content" > "$tmp"

  if ! bash -n "$tmp" >> "$LOG_FILE" 2>&1; then
    rm -f "$tmp"
    die "Скачанный скрипт не прошёл проверку синтаксиса (bash -n). Обновление отменено."
  fi

  cleanup_old_script_copies
  mv -f "$tmp" "$SCRIPT_PATH"
  chmod 700 "$SCRIPT_PATH"

  ok "Скрипт обновлён. Перезапускаю новую версию..."
  log_line "Self-update: restarting via $SCRIPT_PATH ${ORIGINAL_ARGS[*]:-}"
  exec "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

check_for_updates() {
  section "Проверка обновлений"

  local remote_content remote_version
  remote_content="$(fetch_remote_script)"

  if [[ -z "$remote_content" ]]; then
    warn "Не удалось получить актуальную версию скрипта с GitHub. Проверь сеть и попробуй позже."
    return 1
  fi

  remote_version="$(extract_script_version "$remote_content")"

  if [[ -z "$remote_version" ]]; then
    warn "Не удалось определить версию в скачанном скрипте."
    return 1
  fi

  ok "Текущая версия: $SCRIPT_VERSION"
  ok "Версия на GitHub: $remote_version"

  if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
    ok "Установлена последняя версия скрипта."
    return 0
  fi

  if version_gt "$remote_version" "$SCRIPT_VERSION"; then
    echo
    warn "Доступна новая версия скрипта: $remote_version (у тебя $SCRIPT_VERSION)."
    read -rp "  Установить обновление сейчас? [y/N]: " ans

    case "${ans,,}" in
      y|yes|д|да)
        update_self_and_restart "$remote_content"
        ;;
      *)
        ok "Обновление отложено."
        ;;
    esac
  else
    ok "Локальная версия не старше удалённой ($SCRIPT_VERSION vs $remote_version)."
  fi
}

# Тихая проверка обновлений для главного меню: не блокирует, не спрашивает,
# просто подсказывает, что есть новая версия (пункт меню "4").
notify_if_update_available() {
  local remote_content remote_version

  remote_content="$(curl -fsSL --connect-timeout 3 --max-time 6 \
    "${SELF_DOWNLOAD_URL}?ts=$(date +%s)" 2>/dev/null || true)"

  [[ -n "$remote_content" ]] || return 0

  remote_version="$(extract_script_version "$remote_content")"
  [[ -n "$remote_version" ]] || return 0

  if version_gt "$remote_version" "$SCRIPT_VERSION"; then
    echo "${C_YELLOW}  Доступна новая версия: $remote_version (у тебя $SCRIPT_VERSION). Пункт меню «4» — обновить.${C_RESET}"
    echo
  fi
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

install_base_packages() {
  section "1/12 · Базовые пакеты"

  clean_bad_docker_apt_sources

  run_cmd "Обновляю APT index" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update

  run_cmd "Устанавливаю утилиты" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    curl wget gpg ca-certificates nano vim htop btop git unzip jq \
    dnsutils iperf3 mtr-tiny iproute2 net-tools iptables ipset conntrack \
    openssl python3 file
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
    curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o image.deb "$IMAGE_DEB_URL"

  run_cmd "Скачиваю linux-headers XanMod" \
    curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o headers.deb "$HEADERS_DEB_URL"

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

if [[ "\$EUID" -eq 0 ]] && [[ -f "$STATE_FILE" ]] && grep -qx 'need_post_reboot' "$STATE_FILE"; then
  echo
  echo "Eclipse Node Manager: найдено незавершённое продолжение после reboot."
  echo "Обновляю скрипт из GitHub перед продолжением..."

  tmp="\$(mktemp "$SCRIPT_PATH.tmp.XXXXXX")"

  if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \\
    -H 'Cache-Control: no-cache' \\
    -H 'Pragma: no-cache' \\
    -o "\$tmp" \\
    "$SELF_DOWNLOAD_URL?ts=\$(date +%s)" && bash -n "\$tmp"; then
    mv -f "\$tmp" "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"
    echo "Скрипт обновлён."
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
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

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
  compose_v="$(docker_compose version 2>/dev/null | head -n 1 || true)"

  ok "${docker_v:-Docker установлен}"
  ok "${compose_v:-Docker Compose доступен}"
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

  local kernel cc qdisc
  kernel="$(uname -r)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  {
    echo "uname -r:"
    uname -r

    echo
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss || true

    echo
    echo "BBR version:"
    cat /sys/module/tcp_bbr/version 2>/dev/null || true

    echo
    echo "THP:"
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

    echo
    echo "Docker:"
    docker version || true

    echo
    echo "Docker Compose:"
    docker_compose version || true

    echo
    echo "Listening sockets:"
    ss -tulpen || true
  } >> "$LOG_FILE" 2>&1

  ok "Kernel: $kernel"
  ok "TCP CC: ${cc:-unknown}"
  ok "Qdisc: ${qdisc:-unknown}"
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

ask_node_port() {
  local input=""

  while true; do
    read -rp "  NODE_PORT [${DEFAULT_NODE_PORT}]: " input
    input="${input:-$DEFAULT_NODE_PORT}"

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      NODE_PORT="$input"
      ok "Порт ноды: $NODE_PORT"
      return 0
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

setup_remnanode() {
  section "12/12 · Remnawave Node"

  prepare_node_paths
  ask_node_port

  echo
  echo "  Вставь SECRET_KEY из панели Remnawave."
  echo "  Ввод скрытый, это нормально."
  read -rsp "  SECRET_KEY: " SECRET_KEY
  echo

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  cd "$REMNANODE_DIR"

  run_cmd "Скачиваю geosite.dat" \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    -o geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

  run_cmd "Скачиваю geoip.dat" \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    -o geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

  touch "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"

  cat > "$REMNANODE_DIR/.env" <<EOF_ENV
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF_ENV

  chmod 600 "$REMNANODE_DIR/.env"

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
      - ./logs:/var/log/remnanode
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
EOF_COMPOSE

  run_cmd "Запускаю Remnawave Node" docker_compose up -d

  docker_compose ps >> "$LOG_FILE" 2>&1 || true
  docker_compose logs --tail=100 >> "$LOG_FILE" 2>&1 || true

  if ss -tulpen | grep -q ":$NODE_PORT"; then
    ok "Порт $NODE_PORT слушается"
  else
    warn "Порт $NODE_PORT не слушается. Проверь: cd $REMNANODE_DIR && docker compose logs -f --tail=100"
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
  optional_selfsteal
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

main_menu() {
  need_root
  print_banner

  notify_if_update_available

  echo "${C_BOLD}Выбери режим:${C_RESET}"
  echo
  echo "  ${C_GREEN}1${C_RESET}) Автоматическая установка"
  echo "  ${C_CYAN}2${C_RESET}) Ручная установка: показать README/команды"
  echo "  ${C_CYAN}3${C_RESET}) Настройка WARP"
  echo "  ${C_CYAN}4${C_RESET}) Проверить обновления"
  echo "  ${C_YELLOW}5${C_RESET}) Выход"
  echo

  read -rp "  Выбор [1/2/3/4/5]: " choice

  case "${choice:-}" in
    1)
      stage_before_reboot
      ;;
    2)
      print_manual_mode
      ;;
    3)
      run_warp_setup
      ;;
    4)
      check_for_updates
      ;;
    5)
      echo "Выход."
      ;;
    *)
      die "Неверный выбор."
      ;;
  esac
}

case "${1:-}" in
  --continue)
    stage_after_reboot
    ;;
  --auto)
    stage_before_reboot
    ;;
  --manual)
    print_manual_mode
    ;;
  --warp)
    need_root
    run_warp_setup
    ;;
  --check-update)
    need_root
    check_for_updates
    ;;
  *)
    main_menu
    ;;
esac
