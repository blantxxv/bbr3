#!/usr/bin/env bash
set -Eeuo pipefail

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

log() {
  echo -e "\n\033[1;36m[$(date '+%F %T')]\033[0m $*" | tee -a "$LOG_FILE"
}

warn() {
  echo -e "\n\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG_FILE"
}

die() {
  echo -e "\n\033[1;31m[ERROR]\033[0m $*" | tee -a "$LOG_FILE"
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

save_self() {
  mkdir -p "$(dirname "$SCRIPT_PATH")"
  if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
  fi
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

install_base_packages() {
  log "1/12: Установка базовых пакетов"
  apt update
  apt install -y \
    curl wget gpg ca-certificates nano vim htop btop git unzip jq \
    dnsutils iperf3 mtr-tiny iproute2 net-tools iptables ipset conntrack \
    openssl python3 file
}

check_cpu_level() {
  log "2/12: Проверка CPU level для XanMod"

  local level
  level="$(awk 'BEGIN{while(!/flags/) if (getline<"/proc/cpuinfo"!=1) exit; level=1
    if(/lm/&&/cmov/&&/cx16/&&/sse4_1/&&/sse4_2/&&/ssse3/&&/popcnt/) level=2
    if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/) level=3
    if(level==3&&/avx512f/&&/avx512bw/) level=4; print "v"level}')"

  echo "Detected CPU level: ${level:-unknown}" | tee -a "$LOG_FILE"
  echo "Ставим x64v3 даже если CPU показывает v4 — стабильнее для VPS." | tee -a "$LOG_FILE"
}

install_xanmod_kernel() {
  log "3/12: Установка XanMod $KERNEL_VER"

  if uname -r | grep -q "$KERNEL_VER"; then
    log "Уже загружено нужное ядро: $(uname -r)"
    return 0
  fi

  mkdir -p /root/xanmod
  cd /root/xanmod
  rm -f ./*.deb

  curl -fL -o image.deb "$IMAGE_DEB_URL"
  curl -fL -o headers.deb "$HEADERS_DEB_URL"

  file image.deb headers.deb | tee -a "$LOG_FILE"
  dpkg-deb -I image.deb | head | tee -a "$LOG_FILE"
  dpkg-deb -I headers.deb | head | tee -a "$LOG_FILE"

  apt install -y ./image.deb ./headers.deb
  update-grub
  grep -R "xanmod" /boot/grub/grub.cfg | head -20 | tee -a "$LOG_FILE" || true
}

install_profile_continue_hook() {
  log "Создаю автопродолжение после ребута при следующем SSH-входе root"

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
}

maybe_reboot() {
  if uname -r | grep -q "$KERNEL_VER"; then
    log "Ребут не нужен, уже загружено ядро $KERNEL_VER"
    return 0
  fi

  set_state "need_post_reboot"
  install_profile_continue_hook

  log "Первый этап завершён. Сейчас будет reboot."
  echo
  echo "После ребута зайди снова по SSH под root — скрипт сам продолжится и попросит SECRET_KEY."
  echo
  sleep 5
  reboot
}

apply_network_tuning() {
  log "4/12: Сетевой тюнинг"

  modprobe tcp_bbr || true

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

  sysctl --system || true

  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss | tee -a "$LOG_FILE" || true
  cat /sys/module/tcp_bbr/version 2>/dev/null | tee -a "$LOG_FILE" || true
}

disable_thp() {
  log "5/12: Отключение THP"

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

  systemctl daemon-reload
  systemctl enable --now disable-thp.service || true

  cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tee -a "$LOG_FILE" || true
}

enable_rps() {
  log "6/12: RPS"

  local iface
  iface="$(detect_iface)"
  iface="${iface:-eth0}"

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

  systemctl daemon-reload
  systemctl enable --now na-rps-lite.service || true

  cat /sys/class/net/"$iface"/queues/rx-*/rps_cpus 2>/dev/null | tee -a "$LOG_FILE" || true
}

install_docker() {
  log "7/12: Docker"

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker уже установлен"
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

  systemctl enable docker || true
  systemctl restart docker
  docker version | tee -a "$LOG_FILE"
}

disable_llmnr() {
  log "8/12: Закрытие 5355 / LLMNR"

  mkdir -p /etc/systemd/resolved.conf.d

  cat >/etc/systemd/resolved.conf.d/99-no-llmnr.conf <<'EOF_RESOLVED'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF_RESOLVED

  systemctl restart systemd-resolved 2>/dev/null || true
  ss -tulpen | grep 5355 | tee -a "$LOG_FILE" || echo "5355 закрыт" | tee -a "$LOG_FILE"
}

run_final_test() {
  log "9/12: Финальный тест"

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
    echo "Listening sockets:"
    ss -tulpen || true
  } | tee -a "$LOG_FILE"
}

optional_speedtest() {
  log "10/12: Тест скорости"

  echo
  read -rp "Запустить iperf3 speedtest сейчас? [y/N]: " ans
  case "${ans,,}" in
    y|yes|д|да)
      nstat -az TcpRetransSegs TcpOutSegs | tee -a "$LOG_FILE" || true
      bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh) | tee -a "$LOG_FILE" || true
      nstat -az TcpRetransSegs TcpOutSegs | tee -a "$LOG_FILE" || true
      ;;
    *)
      echo "Speedtest пропущен." | tee -a "$LOG_FILE"
      ;;
  esac
}

optional_selfsteal() {
  log "11/12: Selfsteal заглушка"

  echo
  read -rp "Запустить selfsteal.sh заглушку сейчас? [y/N]: " ans
  case "${ans,,}" in
    y|yes|д|да)
      bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) | tee -a "$LOG_FILE" || true
      ;;
    *)
      echo "Selfsteal пропущен." | tee -a "$LOG_FILE"
      ;;
  esac
}

setup_remnanode() {
  log "12/12: Добавление Remnawave Node"

  echo
  echo "Вставь SECRET_KEY из панели Remnawave."
  echo "Ввод скрытый, это нормально."
  read -rsp "SECRET_KEY: " SECRET_KEY
  echo

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  cd "$REMNANODE_DIR"

  wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
  wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

  touch "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"

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

  docker compose up -d
  docker compose ps | tee -a "$LOG_FILE"
  docker compose logs --tail=100 | tee -a "$LOG_FILE" || true
  ss -tulpen | grep ":$NODE_PORT" | tee -a "$LOG_FILE" || true
}

cleanup_continue_hook() {
  rm -f "$PROFILE_HOOK"
  set_state "done"
}

stage_before_reboot() {
  need_root
  save_self

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  warn "Перед установкой ядра убедись, что у VPS есть VNC/Rescue-консоль на случай, если сервер не загрузится после reboot."
  echo
  read -rp "Продолжить установку? [y/N]: " ans
  case "${ans,,}" in
    y|yes|д|да) ;;
    *) die "Отменено пользователем." ;;
  esac

  install_base_packages
  check_cpu_level
  install_xanmod_kernel
  maybe_reboot

  # Если ребут не нужен, сразу продолжаем второй этап.
  stage_after_reboot
}

stage_after_reboot() {
  need_root
  touch "$LOG_FILE"

  log "Продолжение установки после ребута"

  if ! uname -r | grep -q "$KERNEL_VER"; then
    warn "Сейчас загружено ядро: $(uname -r)"
    warn "Ожидалось: $KERNEL_VER"
    warn "Продолжаю настройку, но BBR v3 может быть недоступен."
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

  log "Готово."
  echo
  echo "Лог установки: $LOG_FILE"
  echo "Remnawave Node:"
  echo "  cd $REMNANODE_DIR"
  echo "  docker compose ps"
  echo "  docker compose logs -f --tail=100"
}

case "${1:-}" in
  --continue)
    stage_after_reboot
    ;;
  *)
    stage_before_reboot
    ;;
esac
