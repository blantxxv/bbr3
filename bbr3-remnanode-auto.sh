#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# BBR3 / XanMod / Docker / Remnawave Node auto installer
# ============================================================

STATE_DIR="/var/lib/bbr3-remnanode"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/bbr3-remnanode-install.log"
SCRIPT_PATH="/usr/local/sbin/bbr3-remnanode-install.sh"
PROFILE_HOOK="/etc/profile.d/bbr3-remnanode-continue.sh"

KERNEL_VER="6.19.14-x64v3-xanmod1"
XANMOD_BASE_URL="https://sourceforge.net/projects/xanmod/files/releases/main/6.19.14-xanmod1/6.19.14-x64v3-xanmod1"
IMAGE_DEB_URL="$XANMOD_BASE_URL/linux-image-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"
HEADERS_DEB_URL="$XANMOD_BASE_URL/linux-headers-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"

REMNANODE_DIR="/opt/remnanode"
REMNANODE_LOG_DIR="/var/log/remnanode"
NODE_PORT="2222"

TOTAL_STEPS=12

# ---------- UI ----------

if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RED="\033[1;31m"
  C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"
  C_BLUE="\033[1;34m"
  C_CYAN="\033[1;36m"
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

line() {
  echo -e "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
}

banner() {
  clear 2>/dev/null || true
  echo -e "${C_CYAN}"
  cat <<'EOF'
  ____  ____  ____  _____    ____                               
 | __ )| __ )|  _ \|___ /   |  _ \ ___ _ __ ___  _ __   __ _   
 |  _ \|  _ \| |_) | |_ \   | |_) / _ \ '_ ` _ \| '_ \ / _` |  
 | |_) | |_) |  _ < ___) |  |  _ <  __/ | | | | | | | | (_| |  
 |____/|____/|_| \_\____/   |_| \_\___|_| |_| |_|_| |_|\__,_|  
EOF
  echo -e "${C_RESET}"
  echo -e "${C_BOLD}XanMod BBR3 + сетевой тюнинг + Docker + Remnawave Node${C_RESET}"
  echo
}

log_file_only() {
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

msg() {
  echo -e "$*" | tee -a "$LOG_FILE"
}

step() {
  local n="$1"
  local title="$2"
  echo
  line | tee -a "$LOG_FILE"
  echo -e "${C_BLUE}${C_BOLD}[$n/$TOTAL_STEPS] $title${C_RESET}" | tee -a "$LOG_FILE"
  line | tee -a "$LOG_FILE"
}

ok() {
  echo -e "${C_GREEN}✓${C_RESET} $*" | tee -a "$LOG_FILE"
}

info() {
  echo -e "${C_CYAN}→${C_RESET} $*" | tee -a "$LOG_FILE"
}

warn() {
  echo -e "${C_YELLOW}⚠${C_RESET} $*" | tee -a "$LOG_FILE"
}

die() {
  echo -e "${C_RED}✗ ERROR:${C_RESET} $*" | tee -a "$LOG_FILE"
  echo
  echo "Лог: $LOG_FILE"
  exit 1
}

run() {
  local desc="$1"
  shift

  info "$desc"
  log_file_only "RUN: $*"

  "$@" 2>&1 | tee -a "$LOG_FILE"
  local code=${PIPESTATUS[0]}

  if [[ "$code" -ne 0 ]]; then
    die "Команда завершилась с ошибкой $code: $*"
  fi

  ok "$desc — готово"
}

run_allow_fail() {
  local desc="$1"
  shift

  info "$desc"
  log_file_only "RUN_ALLOW_FAIL: $*"

  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  local code=${PIPESTATUS[0]}
  set -e

  if [[ "$code" -ne 0 ]]; then
    warn "$desc — команда вернула код $code, продолжаю"
  else
    ok "$desc — готово"
  fi
}

pause_before_reboot() {
  echo
  echo -e "${C_YELLOW}${C_BOLD}Сейчас будет reboot.${C_RESET}"
  echo "После перезагрузки зайди снова по SSH под root."
  echo "Скрипт сам продолжится и попросит SECRET_KEY от панели."
  echo
  sleep 5
}

# ---------- helpers ----------

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

prepare_dirs() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
}

save_self() {
  mkdir -p "$(dirname "$SCRIPT_PATH")"

  # При запуске через bash <(curl ...) $0 может быть /dev/fd/N.
  # Поэтому сохраняем скрипт через BASH_SOURCE, если это реальный файл.
  local src="${BASH_SOURCE[0]:-$0}"

  if [[ -f "$src" ]]; then
    if [[ "$(readlink -f "$src" 2>/dev/null || echo "$src")" != "$SCRIPT_PATH" ]]; then
      cp "$src" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      ok "Скрипт сохранён в $SCRIPT_PATH"
    else
      chmod +x "$SCRIPT_PATH"
      ok "Скрипт уже находится в $SCRIPT_PATH"
    fi
  else
    warn "Скрипт запущен не из обычного файла. Для автопродолжения лучше запускать так:"
    echo "curl -fL -o $SCRIPT_PATH https://raw.githubusercontent.com/blantxxv/bbr3/main/bbr3-remnanode-auto.sh"
    echo "chmod +x $SCRIPT_PATH"
    echo "bash $SCRIPT_PATH"
  fi
}

ensure_script_exists_for_continue() {
  if [[ ! -x "$SCRIPT_PATH" ]]; then
    die "Не найден исполняемый $SCRIPT_PATH. Автопродолжение после reboot не сработает. Запусти скрипт файлом, а не через bash <(curl ...)."
  fi
}

set_state() {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$STATE_FILE"
  ok "Состояние установлено: $1"
}

get_state() {
  cat "$STATE_FILE" 2>/dev/null || true
}

detect_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

safe_show_deb_info() {
  local file="$1"
  local label="$2"

  info "Проверяю пакет $label: $file"
  file "$file" | tee -a "$LOG_FILE"

  # ВАЖНО:
  # Не используем `dpkg-deb -I file | head` при pipefail,
  # потому что head может закрыть pipe и dpkg-deb получит SIGPIPE.
  # sed -n безопаснее, плюс стоит `|| true`.
  dpkg-deb -I "$file" | sed -n '1,22p' | tee -a "$LOG_FILE" || true
}

ask_yes_no() {
  local question="$1"
  local default="${2:-N}"
  local ans

  read -rp "$question " ans
  ans="${ans:-$default}"

  case "${ans,,}" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- stages ----------

install_base_packages() {
  step 1 "Базовые пакеты"

  info "Обновляю список пакетов"
  apt update 2>&1 | tee -a "$LOG_FILE"

  info "Ставлю утилиты: curl, wget, git, jq, dnsutils, iperf3, mtr, iptables, conntrack, python3 и т.д."
  apt install -y \
    curl wget gpg ca-certificates nano vim htop btop git unzip jq \
    dnsutils iperf3 mtr-tiny iproute2 net-tools iptables ipset conntrack \
    openssl python3 file 2>&1 | tee -a "$LOG_FILE"

  ok "Базовые пакеты установлены"
}

check_cpu_level() {
  step 2 "Проверка CPU level для XanMod"

  local level
  level="$(awk 'BEGIN{while(!/flags/) if (getline<"/proc/cpuinfo"!=1) exit; level=1
    if(/lm/&&/cmov/&&/cx16/&&/sse4_1/&&/sse4_2/&&/ssse3/&&/popcnt/) level=2
    if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/) level=3
    if(level==3&&/avx512f/&&/avx512bw/) level=4; print "v"level}')"

  info "Detected CPU level: ${level:-unknown}"
  info "Ставим x64v3 даже если CPU показывает v4 — стабильнее для VPS."
  ok "CPU проверен"
}

install_xanmod_kernel() {
  step 3 "Установка XanMod $KERNEL_VER"

  if uname -r | grep -q "$KERNEL_VER"; then
    ok "Уже загружено нужное ядро: $(uname -r)"
    return 0
  fi

  mkdir -p /root/xanmod
  cd /root/xanmod
  rm -f ./*.deb

  run "Скачиваю linux-image XanMod" curl -fL -o image.deb "$IMAGE_DEB_URL"
  run "Скачиваю linux-headers XanMod" curl -fL -o headers.deb "$HEADERS_DEB_URL"

  safe_show_deb_info "image.deb" "linux-image"
  safe_show_deb_info "headers.deb" "linux-headers"

  run "Устанавливаю deb-пакеты ядра" apt install -y ./image.deb ./headers.deb
  run "Обновляю GRUB" update-grub

  info "Проверяю, что XanMod появился в grub.cfg"
  grep -R "xanmod" /boot/grub/grub.cfg | sed -n '1,20p' | tee -a "$LOG_FILE" || true

  ok "Ядро установлено. Для загрузки в него нужен reboot."
}

install_profile_continue_hook() {
  info "Создаю автопродолжение после ребута при следующем SSH-входе root"

  cat > "$PROFILE_HOOK" <<EOF
#!/usr/bin/env bash
if [[ "\$EUID" -eq 0 ]] && [[ -f "$STATE_FILE" ]] && grep -q '^need_post_reboot$' "$STATE_FILE"; then
  echo
  echo "BBR3/Remnawave install: найдено незавершённое продолжение после ребута."
  echo "Запускаю продолжение..."
  "$SCRIPT_PATH" --continue
fi
EOF

  chmod +x "$PROFILE_HOOK"
  ok "Хук создан: $PROFILE_HOOK"
}

maybe_reboot() {
  if uname -r | grep -q "$KERNEL_VER"; then
    ok "Ребут не нужен, уже загружено ядро $KERNEL_VER"
    return 0
  fi

  ensure_script_exists_for_continue
  set_state "need_post_reboot"
  install_profile_continue_hook

  pause_before_reboot
  reboot
}

apply_network_tuning() {
  step 4 "Сетевой тюнинг: BBR3, fq, buffers, conntrack"

  run_allow_fail "Загружаю tcp_bbr" modprobe tcp_bbr

  info "Пишу /etc/sysctl.d/99-net-tuning.conf"

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

  run_allow_fail "Применяю sysctl --system" sysctl --system

  info "Проверка ключевых параметров"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss | tee -a "$LOG_FILE" || true

  if [[ -r /sys/module/tcp_bbr/version ]]; then
    info "Версия BBR:"
    cat /sys/module/tcp_bbr/version | tee -a "$LOG_FILE"
  else
    warn "/sys/module/tcp_bbr/version не найден. Проверяю через modinfo."
    modinfo tcp_bbr 2>/dev/null | grep -i version | tee -a "$LOG_FILE" || true
  fi

  ok "Сетевой тюнинг применён"
}

disable_thp() {
  step 5 "Отключение THP"

  info "Создаю systemd-сервис disable-thp.service"

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

  run "Перечитываю systemd" systemctl daemon-reload
  run_allow_fail "Включаю disable-thp.service" systemctl enable --now disable-thp.service

  info "Проверка THP:"
  cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tee -a "$LOG_FILE" || true

  ok "THP отключён"
}

enable_rps() {
  step 6 "RPS: распределение входящих пакетов по CPU"

  local iface
  iface="$(detect_iface)"
  iface="${iface:-eth0}"

  info "Определён сетевой интерфейс: $iface"
  info "Создаю /usr/local/sbin/enable-rps.sh"

  cat >/usr/local/sbin/enable-rps.sh <<'EOF_RPS'
#!/usr/bin/env bash
set -e

IFACE="${1:-eth0}"
MASK="$(python3 - <<PY
import os
n=os.cpu_count() or 1
print(hex((1 << n) - 1)[2:])
PY
)"

echo "RPS mask: $MASK"

for q in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
  echo "$MASK" > "$q" || true
done

for q in /sys/class/net/$IFACE/queues/rx-*/rps_flow_cnt; do
  echo 32768 > "$q" || true
done

echo 32768 > /proc/sys/net/core/rps_sock_flow_entries || true

cat /sys/class/net/$IFACE/queues/rx-*/rps_cpus || true
EOF_RPS

  chmod +x /usr/local/sbin/enable-rps.sh

  info "Создаю systemd-сервис na-rps-lite.service"

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

  run "Перечитываю systemd" systemctl daemon-reload
  run_allow_fail "Включаю RPS" systemctl enable --now na-rps-lite.service

  info "Проверка RPS:"
  cat /sys/class/net/"$iface"/queues/rx-*/rps_cpus 2>/dev/null | tee -a "$LOG_FILE" || true

  ok "RPS настроен"
}

install_docker() {
  step 7 "Docker"

  if ! command -v docker >/dev/null 2>&1; then
    run "Устанавливаю Docker через get.docker.com" sh -c 'curl -fsSL https://get.docker.com | sh'
  else
    ok "Docker уже установлен"
  fi

  mkdir -p /etc/docker

  info "Пишу /etc/docker/daemon.json: ротация логов, ulimits, live-restore"

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

  run_allow_fail "Включаю Docker в автозагрузку" systemctl enable docker
  run "Перезапускаю Docker" systemctl restart docker

  info "Проверка Docker:"
  docker version | tee -a "$LOG_FILE"

  ok "Docker готов"
}

disable_llmnr() {
  step 8 "Закрытие 5355 / LLMNR"

  mkdir -p /etc/systemd/resolved.conf.d

  info "Отключаю LLMNR и MulticastDNS в systemd-resolved"

  cat >/etc/systemd/resolved.conf.d/99-no-llmnr.conf <<'EOF_RESOLVED'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF_RESOLVED

  run_allow_fail "Перезапускаю systemd-resolved" systemctl restart systemd-resolved

  info "Проверка порта 5355:"
  ss -tulpen | grep 5355 | tee -a "$LOG_FILE" || echo "5355 закрыт" | tee -a "$LOG_FILE"

  ok "LLMNR/5355 обработан"
}

run_final_test() {
  step 9 "Финальный тест системы"

  {
    echo "Kernel:"
    uname -r
    echo

    echo "Network sysctl:"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss || true
    echo

    echo "BBR version:"
    cat /sys/module/tcp_bbr/version 2>/dev/null || modinfo tcp_bbr 2>/dev/null | grep -i version || true
    echo

    echo "THP:"
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo

    echo "Docker:"
    docker version || true
    echo

    echo "Listening sockets:"
    ss -tulpen || true
  } | tee -a "$LOG_FILE"

  ok "Финальный тест завершён"
}

optional_speedtest() {
  step 10 "Тест скорости iperf3"

  if ask_yes_no "Запустить iperf3 speedtest сейчас? [y/N]:" "N"; then
    info "Счётчики TCP до теста"
    nstat -az TcpRetransSegs TcpOutSegs | tee -a "$LOG_FILE" || true

    info "Запускаю speedtest"
    bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh) | tee -a "$LOG_FILE" || true

    info "Счётчики TCP после теста"
    nstat -az TcpRetransSegs TcpOutSegs | tee -a "$LOG_FILE" || true

    ok "Speedtest завершён"
  else
    warn "Speedtest пропущен"
  fi
}

optional_selfsteal() {
  step 11 "Selfsteal заглушка"

  if ask_yes_no "Запустить selfsteal.sh заглушку сейчас? [y/N]:" "N"; then
    info "Запускаю selfsteal.sh"
    bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) | tee -a "$LOG_FILE" || true
    ok "Selfsteal завершён"
  else
    warn "Selfsteal пропущен"
  fi
}

setup_remnanode() {
  step 12 "Remnawave Node"

  echo
  echo -e "${C_BOLD}Вставь SECRET_KEY из панели Remnawave.${C_RESET}"
  echo "Ввод скрытый, это нормально."
  read -rsp "SECRET_KEY: " SECRET_KEY
  echo

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  cd "$REMNANODE_DIR"

  run "Скачиваю geosite.dat" wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
  run "Скачиваю geoip.dat" wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

  touch "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"
  ok "Логи подготовлены: $REMNANODE_LOG_DIR"

  info "Создаю $REMNANODE_DIR/docker-compose.yml"

  cat > "$REMNANODE_DIR/docker-compose.yml" <<EOF_COMPOSE
name: remnanode

services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - './geosite.dat:/usr/local/share/xray/geosite.dat'
      - './geoip.dat:/usr/local/share/xray/geoip.dat'
      - '$REMNANODE_LOG_DIR:/var/log/remnanode'
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY=$SECRET_KEY
EOF_COMPOSE

  run "Запускаю Remnawave Node" docker compose up -d

  info "Статус контейнера:"
  docker compose ps | tee -a "$LOG_FILE"

  info "Последние логи:"
  docker compose logs --tail=100 | tee -a "$LOG_FILE" || true

  info "Проверка порта $NODE_PORT:"
  ss -tulpen | grep ":$NODE_PORT" | tee -a "$LOG_FILE" || true

  ok "Remnawave Node установлен"
}

cleanup_continue_hook() {
  rm -f "$PROFILE_HOOK"
  set_state "done"
  ok "Автопродолжение очищено"
}

stage_before_reboot() {
  need_root
  prepare_dirs
  banner
  save_self

  warn "Перед установкой ядра убедись, что у VPS есть VNC/Rescue-консоль на случай, если сервер не загрузится после reboot."
  echo
  if ! ask_yes_no "Продолжить установку? [y/N]:" "N"; then
    die "Отменено пользователем."
  fi

  install_base_packages
  check_cpu_level
  install_xanmod_kernel
  maybe_reboot

  # Если ребут не нужен, сразу продолжаем второй этап.
  stage_after_reboot
}

stage_after_reboot() {
  need_root
  prepare_dirs
  banner

  info "Продолжение установки после ребута"

  if ! uname -r | grep -q "$KERNEL_VER"; then
    warn "Сейчас загружено ядро: $(uname -r)"
    warn "Ожидалось: $KERNEL_VER"
    warn "Продолжаю настройку, но BBR v3 может быть недоступен."
  else
    ok "Загружено нужное ядро: $(uname -r)"
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
  line
  echo -e "${C_GREEN}${C_BOLD}✓ Установка завершена${C_RESET}"
  line
  echo
  echo "Лог установки: $LOG_FILE"
  echo
  echo "Проверка Remnawave Node:"
  echo "  cd $REMNANODE_DIR"
  echo "  docker compose ps"
  echo "  docker compose logs -f --tail=100"
  echo
}

case "${1:-}" in
  --continue)
    stage_after_reboot
    ;;
  *)
    stage_before_reboot
    ;;
esac
