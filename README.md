# Настройка VPS: XanMod, BBR, сетевой тюнинг, Docker и Remnawave Node

> ⚠️ Перед установкой ядра убедись, что у VPS есть доступ к VNC/Rescue-консоли на случай, если сервер не загрузится после `reboot`.
>
> Рекомендуется выполнять команды от `root`.

---

## 1. Базовые пакеты

```bash
apt update
apt install -y curl wget gpg ca-certificates nano vim htop btop git unzip jq dnsutils iperf3 mtr-tiny iproute2 net-tools iptables ipset conntrack openssl python3 file
```

---

## 2. Проверка CPU level для XanMod

```bash
LEVEL=$(awk 'BEGIN{while(!/flags/) if (getline<"/proc/cpuinfo"!=1) exit; level=1
  if(/lm/&&/cmov/&&/cx16/&&/sse4_1/&&/sse4_2/&&/ssse3/&&/popcnt/) level=2
  if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/) level=3
  if(level==3&&/avx512f/&&/avx512bw/) level=4; print "v"level}')
echo "$LEVEL"
```

Даже если покажет `v4`, ставим `x64v3`, как раньше — стабильнее для VPS.

---

## 3. Установка XanMod x64v3

```bash
mkdir -p /root/xanmod
cd /root/xanmod
rm -f *.deb
```

Скачиваем kernel image:

```bash
curl -fL -o image.deb "https://sourceforge.net/projects/xanmod/files/releases/main/6.19.14-xanmod1/6.19.14-x64v3-xanmod1/linux-image-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"
```

Скачиваем headers:

```bash
curl -fL -o headers.deb "https://sourceforge.net/projects/xanmod/files/releases/main/6.19.14-xanmod1/6.19.14-x64v3-xanmod1/linux-headers-6.19.14-x64v3-xanmod1_6.19.14-x64v3-xanmod1-0~20260422.gb95d921_amd64.deb/download"
```

Проверяем пакеты:

```bash
file image.deb headers.deb
dpkg-deb -I image.deb | head
dpkg-deb -I headers.deb | head
```

Если пакеты нормальные:

```bash
apt install -y ./image.deb ./headers.deb
update-grub
grep -R "xanmod" /boot/grub/grub.cfg
reboot
```

После ребута:

```bash
uname -r
modprobe tcp_bbr
cat /sys/module/tcp_bbr/version 2>/dev/null || modinfo tcp_bbr | grep -i version
```

Ожидаемый результат:

```text
6.19.14-x64v3-xanmod1
3
```

---

## 4. Сетевой тюнинг

```bash
modprobe tcp_bbr
```

Создаём sysctl-конфиг:

```bash
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
```

Применяем:

```bash
sysctl --system
```

Проверяем:

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss
cat /sys/module/tcp_bbr/version
```

---

## 5. Отключение THP

Создаём systemd-сервис:

```bash
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
```

Включаем:

```bash
systemctl daemon-reload
systemctl enable --now disable-thp.service
```

Проверяем:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
```

Ожидаемый результат:

```text
always madvise [never]
```

---

## 6. RPS

Создаём скрипт:

```bash
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
```

Делаем скрипт исполняемым:

```bash
chmod +x /usr/local/sbin/enable-rps.sh
```

Создаём systemd-сервис:

```bash
cat >/etc/systemd/system/na-rps-lite.service <<'EOF_SERVICE'
[Unit]
Description=Enable RPS dynamically
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/enable-rps.sh eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
```

Включаем:

```bash
systemctl daemon-reload
systemctl enable --now na-rps-lite.service
```

Проверяем:

```bash
cat /sys/class/net/eth0/queues/rx-*/rps_cpus
```

---

## 7. Docker

Устанавливаем Docker:

```bash
curl -fsSL https://get.docker.com | sh
```

Создаём конфиг Docker daemon:

```bash
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
```

Перезапускаем Docker:

```bash
systemctl restart docker
docker version
```

---

## 8. Закрытие 5355 / LLMNR

Если используется `systemd-resolved`, отключаем LLMNR и MulticastDNS:

```bash
mkdir -p /etc/systemd/resolved.conf.d

cat >/etc/systemd/resolved.conf.d/99-no-llmnr.conf <<'EOF_RESOLVED'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF_RESOLVED
```

Перезапускаем `systemd-resolved`:

```bash
systemctl restart systemd-resolved 2>/dev/null || true
```

Проверяем:

```bash
ss -tulpen | grep 5355 || echo "5355 закрыт"
```

---

## 9. Финальный тест

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_min_snd_mss
cat /sys/module/tcp_bbr/version
cat /sys/kernel/mm/transparent_hugepage/enabled
docker version
ss -tulpen
```

---

## 10. Тест скорости

Смотрим retransmits до теста:

```bash
nstat -az TcpRetransSegs TcpOutSegs
```

Запускаем speedtest:

```bash
bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)
```

Смотрим retransmits после теста:

```bash
nstat -az TcpRetransSegs TcpOutSegs
```

---

## 11. Selfsteal заглушка

```bash
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh)
```

---

## 12. Добавление Remnawave Node

Создаём директории:

```bash
mkdir -p /opt/remnanode /var/log/remnanode
cd /opt/remnanode
```

Скачиваем базы правил:

```bash
wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
```

Создаём файлы логов:

```bash
touch /var/log/remnanode/access.log /var/log/remnanode/error.log
```

Создаём `docker-compose.yml`:

```bash
cat > /opt/remnanode/docker-compose.yml <<'EOF_COMPOSE'
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
      - '/var/log/remnanode:/var/log/remnanode'
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="СЕКРЕТ_С_ПАНЕЛИ"
EOF_COMPOSE
```

Запускаем ноду:

```bash
docker compose up -d
```

---

## 13. Быстрая проверка Remnawave Node

```bash
cd /opt/remnanode
docker compose ps
docker compose logs --tail=100
ss -tulpen | grep 2222
```

Если нужно смотреть логи в реальном времени:

```bash
cd /opt/remnanode
docker compose logs -f --tail=100
```

---

## Примечание по образу ноды

Оставляем именно этот образ:

```yaml
image: remnawave/node:latest
```

Не использовать:

```yaml
image: ghcr.io/remnawave/nodelatest
```

Такой вариант ранее отдавал ошибку registry `denied`.
# bbr3
