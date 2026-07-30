#!/usr/bin/env bash

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")

SCRIPT_VERSION="3.7.8"

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

# Режим «только нода»: ставим Docker, транспорт и контейнер, без ядра XanMod,
# сетевого тюнинга, лимитов, THP/RPS и reboot. Влияет и на заголовки шагов —
# нумерация вида «7/12» относится к полному сценарию и здесь врала бы.
NODE_ONLY=0

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

# Полный target REALITY (host:port), куда проксируется «легитимный» трафик.
# selfsteal → 127.0.0.1:<локальный порт Caddy>; без selfsteal → <чужой SNI>:443
# (маскировка под реальный внешний сайт, «borrowed SNI»). Заполняется в
# ask_reality_params по флагу SELFSTEAL_ENABLED.
REALITY_TARGET=""

# Флаг: запускался ли selfsteal.sh (Caddy-маскировка на этом же сервере).
# Ставится в optional_selfsteal. От него зависит, какой SNI/target спрашивать:
# при selfsteal — свой домен Caddy и локальный порт, без него — внешний домен.
SELFSTEAL_ENABLED=0

# VLESS Encryption (mlkem768x25519plus, пост-квант ML-KEM-768). Опциональный
# слой шифрования поверх VLESS, независимый от REALITY/TLS. Спрашивается перед
# генерацией конфига. REALITY_DECRYPTION идёт в inbound (settings.decryption),
# REALITY_ENCRYPTION — строка для клиента/панели. Режим фиксируем random
# (самый устойчивый к DPI). "none" = шифрование выключено.
REALITY_ENCRYPTION_ENABLED=0
REALITY_DECRYPTION="none"
REALITY_ENCRYPTION=""
VLESS_ENC_MODE="random"

# Репозиторий ядра Xray-core (для пункта меню «Обновление ядра xray»).
# Имя ассета (zip) выбирается по архитектуре в xray_asset_for_arch.
XRAY_CORE_REPO="XTLS/Xray-core"

# Куда ставить wrapper-команду для быстрого запуска (eclipse).
ECLIPSE_CMD="/usr/local/bin/eclipse"

# Общий каталог состояния Eclipse: домен панели, режим фаервола, лимит канала.
# Определён ЗДЕСЬ, а не в секции фаервола ниже, потому что на него ссылаются
# присваивания верхнего уровня из более ранних секций (например,
# ECLIPSE_SHAPE_FILE). Под `set -u` ссылка на ещё не заданную переменную роняет
# скрипт сразу при загрузке — и bash -n такое не ловит, только реальный запуск.
ECLIPSE_FW_DIR="/etc/eclipse"

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
DEFAULT_HY2_PORT="443"
TLS_VLESS_PORT="443"
HY2_PORT="443"

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

# Чистит экран вместе с буфером прокрутки и уводит курсор в левый верхний угол.
#
# Своя реализация вместо `clear`: терминфо-шный clear на многих терминалах
# отправляет только \033[2J (видимая область), а прокрутка остаётся забита
# предыдущим выводом, из-за чего меню «тонет» в старых логах. \033[3J чистит
# именно scrollback. Ту же функцию скрипт прописывает в ~/.bashrc/~/.zshrc
# (install_clear_fix), чтобы и ручной `clear` в консоли вёл себя так же.
clear_screen() {
  printf '\033[2J\033[3J\033[H' 2>/dev/null || clear 2>/dev/null || true
}

print_banner() {
  clear_screen

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
  local title="$*"

  # Заголовки шагов полного сценария пронумерованы («7/12 · Docker»).
  # В режиме «только нода» выполняется меньше половины из них, поэтому номер
  # срезаем — иначе прогресс выглядит сломанным (1/12 → 7/12 → 12/12).
  [[ "${NODE_ONLY:-0}" -eq 1 ]] && title="${title#*/12 · }"

  echo
  echo "${C_BLUE}${C_BOLD}▶ $title${C_RESET}"
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
  local tty_state

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START: $msg"
  log_line "CMD: $*"

  # Шаги здесь неинтерактивные, поэтому stdin отвязываем от терминала:
  # так команда не сможет ни съесть ввод, ни оставить tty в своём режиме,
  # ни молча зависнуть на невидимом вопросе (вывод-то уходит в лог).
  # Состояние tty всё равно снимаем и возвращаем — на случай, если команда
  # лезет в терминал напрямую через /dev/tty.
  tty_state="$(save_tty_state)"

  if [[ "$DEBUG" == "1" ]]; then
    echo "${C_CYAN}  [..]${C_RESET} $msg"
    "$@" < /dev/null 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    restore_tty_state "$tty_state"
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
  "$@" < /dev/null >> "$LOG_FILE" 2>&1
  local rc="$?"
  set -e

  cleanup_spinner
  printf "\r\033[K"
  restore_tty_state "$tty_state"

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
  local tty_state

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START: $msg"
  log_line "SHELL: $cmd"

  # Как и в run_cmd: неинтерактивный шаг, поэтому stdin от терминала отвязан,
  # а состояние tty снимается и возвращается (см. комментарий там).
  tty_state="$(save_tty_state)"

  if [[ "$DEBUG" == "1" ]]; then
    echo "${C_CYAN}  [..]${C_RESET} $msg"
    bash -lc "$cmd" < /dev/null 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    restore_tty_state "$tty_state"
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
  bash -lc "$cmd" < /dev/null >> "$LOG_FILE" 2>&1
  local rc="$?"
  set -e

  cleanup_spinner
  printf "\r\033[K"
  restore_tty_state "$tty_state"

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

# ── Скорость загрузок ────────────────────────────────────────────────────────
#
# Все скачивания в скрипте идут через run_download и печатают фактическую
# среднюю скорость с цветовой оценкой. Это не украшательство: именно по этой
# строке видно, что установка «висит» не из-за скрипта, а из-за медленного
# зеркала — и что имеет смысл прервать шаг и перезапустить.
#
# Пороги в МБ/с (1 МБ/с = 8 Мбит/с):
DL_SPEED_GOOD_MBS=10    # >= 10 МБ/с (~80 Мбит/с) — зелёный
DL_SPEED_OKAY_MBS=2     # 2..10 МБ/с — жёлтый; ниже — красный

# Ниже этой средней скорости за столько секунд curl обрывает попытку и уходит
# на --retry (часто это выводит на другое зеркало). Файлы меньше DL_STALL_SECS
# секунд качаются быстрее, чем срабатывает проверка, поэтому мелким загрузкам
# это не мешает.
DL_STALL_BYTES=51200    # 50 КБ/с
DL_STALL_SECS=30

# Ниже этого объёма оценка скорости не имеет смысла: время передачи
# определяется рукопожатием TLS и задержкой до сервера, а не каналом. Такие
# загрузки показываем без вердикта, иначе быстрый сервер получал бы красное
# «низкая» просто потому, что файл маленький.
DL_MIN_MEASURABLE_BYTES=1048576   # 1 МБ

# Печатает цветную строку по данным curl: $1 — байт/с, $2 — всего байт,
# $3 — секунд. Вся арифметика в awk: в bash нет плавающей точки, а curl
# отдаёт скорость дробным числом.
format_speed() {
  awk -v bps="${1:-0}" -v bytes="${2:-0}" -v secs="${3:-0}" \
      -v good="$DL_SPEED_GOOD_MBS" -v okay="$DL_SPEED_OKAY_MBS" \
      -v minb="$DL_MIN_MEASURABLE_BYTES" \
      -v g="$C_GREEN" -v y="$C_YELLOW" -v r="$C_RED" -v d="$C_DIM" -v z="$C_RESET" '
    BEGIN {
      mbs  = bps / 1048576;
      mbit = bps * 8 / 1000000;

      if (bytes < minb) {
        printf "%s%.0f КБ за %.1f с (слишком мало для оценки скорости)%s",
               d, bytes / 1024, secs, z;
        exit;
      }

      if (mbs >= good)      { col = g; mark = "хорошая"; }
      else if (mbs >= okay) { col = y; mark = "средняя"; }
      else                  { col = r; mark = "низкая";  }

      printf "%s%.1f МБ/с · %.0f Мбит/с · %s%s %s(%.1f МБ за %.1f с)%s",
             col, mbs, mbit, mark, z, d, bytes / 1048576, secs, z;
    }'
}

# Скачивает файл и печатает фактическую скорость.
# run_download "Сообщение" <файл> <url> [доп. аргументы curl...]
run_download() {
  local msg="$1" dest="$2" url="$3"
  shift 3

  local stats rc bps bytes secs

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START DL: $msg"
  log_line "URL: $url"

  if [[ "$DEBUG" != "1" ]]; then
    spinner "$msg" &
    SPINNER_PID="$!"
  else
    echo "${C_CYAN}  [..]${C_RESET} $msg"
  fi

  # -w печатает статистику в stdout, тело идёт в файл через -o, поэтому
  # подстановка команды забирает ровно три числа и ничего лишнего.
  set +e
  stats="$(curl -fL --retry 3 --retry-delay 2 $CURL_RETRY_ALL_ERRORS_FLAG \
    --speed-limit "$DL_STALL_BYTES" --speed-time "$DL_STALL_SECS" \
    -w '%{speed_download} %{size_download} %{time_total}' \
    -o "$dest" "$@" "$url" 2>>"$LOG_FILE")"
  rc=$?
  set -e

  if [[ "$DEBUG" != "1" ]]; then
    cleanup_spinner
    printf "\r\033[K"
  fi

  read -r bps bytes secs <<< "${stats:-0 0 0}"
  log_line "DL stats: rc=$rc speed=${bps:-0}B/s size=${bytes:-0} time=${secs:-0}"

  if [[ "$rc" -eq 0 ]]; then
    ok "$msg"
    echo "         $(format_speed "${bps:-0}" "${bytes:-0}" "${secs:-0}")"
    return 0
  fi

  # 28 — таймаут curl, в том числе срабатывание --speed-limit. Для пользователя
  # это принципиально другая ситуация, чем 404: файл есть, но зеркало не тянет.
  if [[ "$rc" -eq 28 ]]; then
    fail "$msg — зеркало отдаёт медленнее ${DL_STALL_BYTES} Б/с, попытки прерваны."
  else
    fail "$msg (curl rc=$rc)"
  fi

  log_line "FAIL DL: $msg rc=$rc"
  return "$rc"
}

# Есть ли у процесса управляющий терминал, и можно ли писать/читать /dev/tty.
#
# Проверять `[[ -r /dev/tty ]]` нельзя: access() смотрит только права на файл
# устройства (0666), поэтому тест проходит и там, где управляющего терминала
# нет вовсе — а сам редирект падает с ENXIO. Поэтому пробуем открыть по-честному
# и запоминаем результат (открытие /dev/tty на каждый вопрос — лишний сисколл).
ASK_TTY_OK=""
have_ctty() {
  if [[ -z "$ASK_TTY_OK" ]]; then
    if { : < /dev/tty; } 2>/dev/null; then ASK_TTY_OK=1; else ASK_TTY_OK=0; fi
  fi

  [[ "$ASK_TTY_OK" -eq 1 ]]
}

# Многие «живые» команды (speedtest, apt с прогресс-барами, инсталляторы)
# переводят tty в свой режим и не всегда его восстанавливают — тогда вывод
# начинает «лесенкой» (потерян ONLCR: \n без \r) или пропадает эхо ввода.
# Снимаем состояние терминала до команды и возвращаем после — того же /dev/tty,
# которое читает ask: иначе при запуске вида `bash <(curl ...)` stty работал бы
# с fd 0, который терминалом не является, и молча ничего не сохранял и не чинил.
save_tty_state() {
  if have_ctty; then
    stty -g < /dev/tty 2>/dev/null || true
    return 0
  fi
  [[ -t 1 ]] || return 0
  stty -g 2>/dev/null || true
}

restore_tty_state() {
  if have_ctty; then
    if [[ -n "${1:-}" ]]; then
      stty "$1" < /dev/tty 2>/dev/null && { tty_ensure_sane; return 0; }
    fi
    stty sane < /dev/tty 2>/dev/null || true
    tty_ensure_sane
    return 0
  fi

  [[ -t 1 ]] || return 0
  if [[ -n "${1:-}" ]]; then
    stty "$1" 2>/dev/null && { tty_ensure_sane; return 0; }
  fi
  stty sane 2>/dev/null || true
  tty_ensure_sane
}

# Возвращает терминал в нормальный построчный режим: canonical + эхо +
# работающий backspace. Нужно потому, что внешние команды (apt с прогресс-барами,
# certbot, docker, сторонние инсталляторы вроде selfsteal.sh) переводят tty в
# свой режим и не всегда его восстанавливают. Тогда стереть введённое нельзя:
# символ стирания попадает прямо в строку как ^H, и ответ вида "0^H2" не
# совпадает ни с одним пунктом меню — выглядит как «скрипт проглотил ввод».
tty_ensure_sane() {
  # Настраиваем именно /dev/tty, а не fd 0: скрипт часто запускают как
  # `bash <(curl ...)`, и тогда stdin процесса — вообще не терминал, а stty
  # правил бы не тот дескриптор (или молча ничего не делал).
  # Явный набор флагов аккуратнее, чем stty sane (не сбрасывает лишнего).
  # Если терминал не понял какой-то флаг — падаем на sane.
  if have_ctty; then
    stty icanon echo echoe echok icrnl onlcr < /dev/tty 2>/dev/null && return 0
    stty sane < /dev/tty 2>/dev/null || true
    return 0
  fi

  [[ -t 0 && -t 1 ]] || return 0

  stty icanon echo echoe echok icrnl onlcr 2>/dev/null && return 0
  stty sane 2>/dev/null || true
  return 0
}

# Применяет семантику backspace к уже прочитанной строке и вырезает остальные
# управляющие символы. Страховка на случай, если tty всё-таки был в «сломанном»
# режиме и стирание пришло в буфер символом (^H / DEL), а не удалило предыдущий.
apply_backspaces() {
  local s="${1:-}" out="" ch i

  for (( i = 0; i < ${#s}; i++ )); do
    ch="${s:i:1}"
    case "$ch" in
      $'\b'|$'\177') out="${out%?}" ;;
      *) [[ "$ch" == [[:cntrl:]] ]] || out+="$ch" ;;
    esac
  done

  printf '%s' "$out"
}

# Единая точка интерактивного ввода: нормализует терминал ПЕРЕД чтением,
# читает строку и чистит её от управляющих символов.
# Использование: ask ИМЯ_ПЕРЕМЕННОЙ "текст вопроса"
# Код возврата — от read, поэтому конструкции вида `ask choice "..." || choice=0`
# продолжают работать (EOF/закрытый stdin).
ask() {
  local __ask_var="$1" __ask_prompt="${2:-}" __ask_raw="" __ask_rc=0

  tty_ensure_sane

  # -e включает readline, и это принципиально для стирания: readline сам
  # трактует И ^H (BS, 0x08), И ^? (DEL, 0x7F) как «удалить символ». Без него
  # стирание работает только если нажатая клавиша совпала с erase-символом
  # терминала: `stty sane` ставит erase=^?, а множество клиентов (PuTTY с
  # «Backspace = Control-H», часть Windows-терминалов) присылают BS — он не
  # совпадал, tty не стирал и печатал его в строку как ^H. Отсюда и был
  # «Имя ноды: safeex^Hcl^H^H» на экране.
  #
  # Ключевой момент — редирект `< /dev/tty`. bash включает readline только
  # когда fd 0 РЕАЛЬНО терминал, а при типичном запуске `bash <(curl ...)`
  # (и тем более из пайпа) stdin процесса терминалом не является. Без редиректа
  # -e молча выключался, ввод шёл через канонический режим ядра — и весь блок
  # выше опять переставал работать, из-за чего ^H вылезал по всему меню.
  if have_ctty; then
    read -e -rp "$__ask_prompt" __ask_raw < /dev/tty || __ask_rc=$?
  elif [[ -t 0 ]]; then
    read -e -rp "$__ask_prompt" __ask_raw || __ask_rc=$?
  else
    read -rp "$__ask_prompt" __ask_raw || __ask_rc=$?
  fi

  printf -v "$__ask_var" '%s' "$(apply_backspaces "$__ask_raw")"
  return "$__ask_rc"
}

# То же, но без эха (пароли/ключи). Перевод строки печатаем сами.
# readline здесь применить нельзя (-e показал бы ввод), поэтому стирание
# вычищается уже из прочитанной строки через apply_backspaces — эха всё равно
# нет, так что визуально ничего не портится.
ask_secret() {
  local __ask_var="$1" __ask_prompt="${2:-}" __ask_raw="" __ask_rc=0

  tty_ensure_sane

  if have_ctty; then
    read -rsp "$__ask_prompt" __ask_raw < /dev/tty || __ask_rc=$?
  else
    read -rsp "$__ask_prompt" __ask_raw || __ask_rc=$?
  fi
  echo

  printf -v "$__ask_var" '%s' "$(apply_backspaces "$__ask_raw")"
  return "$__ask_rc"
}

run_shell_live() {
  local msg="$1"
  local cmd="$2"
  local tty_state

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START LIVE: $msg"
  log_line "SHELL LIVE: $cmd"

  echo "${C_CYAN}  [..]${C_RESET} $msg"
  echo "${C_DIM}  ────────────────────────────────────────────────────────────${C_RESET}"

  tty_state="$(save_tty_state)"

  set +e
  bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
  local rc="${PIPESTATUS[0]}"
  set -e

  restore_tty_state "$tty_state"

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

# Как run_shell_live, но команду можно ОТМЕНИТЬ по Ctrl+C, не роняя весь
# скрипт: во время выполнения INT перехватывается самим скриптом (trap ':'),
# поэтому сигнал получает только дерево процессов теста — оно завершается, а
# скрипт продолжает работу и возвращается в меню. Нужно для тестов скорости и
# прочих долгих шагов, которые могут «зависнуть» или идти слишком долго.
# Третий аргумент раньше задавал задержку фонового напоминания об отмене —
# оно убрано: асинхронная запись в тот же stdout влезала в середину строки
# живого вывода (speedtest/apt) и разносила весь экран. Подсказка про Ctrl+C
# теперь печатается один раз до старта команды. Аргумент оставлен для
# совместимости с существующими вызовами и игнорируется.
run_live_cancellable() {
  local msg="$1"
  local cmd="$2"
  local rc=0
  local tty_state

  mkdir -p "$(dirname "$LOG_FILE")"
  log_line "START LIVE-CANCEL: $msg"
  log_line "SHELL LIVE: $cmd"

  echo "${C_CYAN}  [..]${C_RESET} $msg"
  echo "${C_DIM}  Идёт слишком долго или зависло? Нажми Ctrl+C — отменится только этот тест, скрипт продолжит работу.${C_RESET}"
  echo "${C_DIM}  ────────────────────────────────────────────────────────────${C_RESET}"

  tty_state="$(save_tty_state)"

  set +e
  # Пока идёт тест, скрипт игнорирует Ctrl+C сам, но дочерние процессы теста
  # (в той же группе процессов) сигнал получают и завершаются.
  trap ':' INT
  bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  trap - INT
  set -e

  restore_tty_state "$tty_state"

  echo "${C_DIM}  ────────────────────────────────────────────────────────────${C_RESET}"

  # rc>128 — тест прерван сигналом (Ctrl+C). Это штатная отмена, не ошибка.
  if [[ "$rc" -gt 128 ]]; then
    warn "$msg — отменено (Ctrl+C). Продолжаю."
    log_line "CANCELLED: $msg rc=$rc"
    return 0
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "$msg"
    log_line "OK LIVE-CANCEL: $msg"
    return 0
  fi

  fail "$msg"
  log_line "FAIL LIVE-CANCEL: $msg rc=$rc"
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

    if ! script_loads_ok "$tmp"; then
      rm -f "$tmp"
      warn "Удалённый скрипт новее, но падает при загрузке. Оставляю текущую локальную копию."
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

# Проверяет, что скрипт не только парсится, но и ЗАГРУЖАЕТСЯ: прогоняет его с
# --help, то есть исполняет весь верхний уровень.
#
# Зачем отдельно от bash -n: под `set -u` ссылка на переменную, которая задаётся
# ниже по файлу (например VAR="$LATER_VAR/x" на верхнем уровне), проходит
# проверку синтаксиса, но роняет скрипт сразу при старте — "unbound variable".
# Именно так версия 3.7.0 окирпичила команду eclipse на нодах: bash -n был
# чистый, а скрипт не запускался вообще.
script_loads_ok() {
  local f="$1"

  [[ -s "$f" ]] || return 1
  timeout 30 bash "$f" --help >/dev/null 2>>"$LOG_FILE"
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

  # Мало распарситься — надо ещё загрузиться. Без этой проверки скрипт с
  # unbound variable на верхнем уровне устанавливается и убивает команду eclipse.
  if ! script_loads_ok "$tmp"; then
    rm -f "$tmp"
    die "Скачанный скрипт не запускается (падает при загрузке, см. $LOG_FILE). Обновление отменено, текущая версия оставлена."
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

  ask ans "  Установить файл с GitHub сейчас? [y/N]: "

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

# Запускает apt-get update и, если какой-то СТОРОННИЙ репозиторий сломан
# (404/нет Release — типично для временно недоступного deb.xanmod.org или
# чужого репо, оставшегося от прошлых запусков), отключает именно его .list
# и повторяет — чтобы не валить всю установку. Официальные репозитории
# дистрибутива (ubuntu/debian) не трогает (их сбой — это временная сеть).
apt_update_resilient() {
  local msg="Обновляю APT index"
  local backup_dir="/etc/apt/sources.list.d.disabled-by-eclipse"
  local attempt out rc err_urls url host files f disabled

  mkdir -p "$backup_dir" "$(dirname "$LOG_FILE")"

  for attempt in 1 2 3; do
    log_line "START: $msg (попытка $attempt)"
    set +e
    out="$(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" >> "$LOG_FILE"

    if [[ $rc -eq 0 ]]; then
      ok "$msg"
      return 0
    fi

    # URL-ы репозиториев, давших ошибку (строки Err:/E: The repository ...).
    err_urls="$(printf '%s\n' "$out" \
      | grep -iE '^(Err:|E: The repository)' \
      | grep -oE 'https?://[^ '"'"']+' | sort -u)"

    disabled=0
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      host="$(echo "$url" | sed -E 's~https?://([^/]+).*~\1~')"

      # Официальные репозитории дистрибутива не отключаем — их ошибка это сеть.
      case "$host" in
        *.ubuntu.com|*.debian.org|ubuntu.com|debian.org)
          warn "Ошибка обновления официального репозитория ($host) — вероятно, временная сеть."
          continue
          ;;
      esac

      files="$(grep -rlE -- "$host" /etc/apt/sources.list.d 2>/dev/null || true)"
      while IFS= read -r f; do
        [[ -n "$f" && -e "$f" ]] || continue
        warn "Сломанный сторонний репозиторий ($host) мешает apt update — отключаю: $f"
        mv -f "$f" "$backup_dir/$(basename "$f").$(date +%s)" 2>/dev/null || rm -f "$f"
        disabled=1
      done <<< "$files"
    done <<< "$err_urls"

    # Нечего отключать — повторять смысла нет.
    [[ "$disabled" -eq 1 ]] || break
  done

  # Финальная попытка после отключения сломанных репозиториев.
  set +e
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update >> "$LOG_FILE" 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "$msg (после отключения сломанных сторонних репозиториев)"
    return 0
  fi

  fail "$msg"
  show_last_log
  return "$rc"
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
    ask choice "  Выбор [1/2]: "

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

  apt_update_resilient

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

  # --batch --yes: молча перезаписать ключ, если файл уже существует (при
  # повторном запуске), иначе gpg зависает на интерактивном "Overwrite? (y/N)"
  # прямо поверх спиннера.
  if ! run_shell "Добавляю GPG-ключ XanMod" \
    "set -o pipefail; curl -fsSL https://dl.xanmod.org/archive.key | gpg --batch --yes --dearmor -o '$XANMOD_KEYRING'"; then
    return 1
  fi

  # Suite репозитория — КОДОВОЕ ИМЯ дистрибутива (bookworm, noble, trixie...),
  # как в текущей официальной инструкции XanMod:
  #   deb [signed-by=...] http://deb.xanmod.org $(lsb_release -sc) main
  #
  # Раньше здесь было жёстко прописано `releases`. Этот suite XanMod убрал —
  # https://deb.xanmod.org/dists/releases/Release теперь отдаёт 404, apt-get
  # update падает, и скрипт делал ложный вывод «репозиторий недоступен, беру
  # ядро с SourceForge». Отсюда и многоминутное скачивание .deb с медленного
  # зеркала при полностью живом APT-репозитории.
  local codename="${OS_CODENAME:-}"
  if [[ -z "$codename" || "$codename" == "unknown" ]]; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi

  if [[ -z "$codename" || "$codename" == "unknown" ]]; then
    warn "Не удалось определить кодовое имя дистрибутива — репозиторий XanMod подключить нельзя."
    return 1
  fi

  # Проверяем ИМЕННО наличие suite до подключения: так мы отличаем «XanMod не
  # собирает пакеты для этого релиза» от «apt упал из-за чужого репозитория».
  local scheme found_scheme=""
  for scheme in https http; do
    if curl -fsI --connect-timeout 10 --max-time 30 \
      "${scheme}://deb.xanmod.org/dists/${codename}/Release" >> "$LOG_FILE" 2>&1; then
      found_scheme="$scheme"
      break
    fi
    log_line "XanMod repo: ${scheme}://deb.xanmod.org/dists/${codename}/Release недоступен"
  done

  if [[ -z "$found_scheme" ]]; then
    warn "XanMod не публикует пакеты для этого релиза (suite '${codename}' на deb.xanmod.org отсутствует)."
    return 1
  fi

  echo "deb [signed-by=$XANMOD_KEYRING] ${found_scheme}://deb.xanmod.org ${codename} main" > "$XANMOD_REPO_LIST"
  log_line "XanMod repo: ${found_scheme}://deb.xanmod.org ${codename} main"

  # apt-get update гоняем тихо: недоступный XanMod — не сбой установки (нода
  # поставится и без своего ядра), поэтому не используем run_cmd, чтобы не
  # пугать красным [FAIL] и не дампить лог.
  local out rc
  set +e
  out="$(env DEBIAN_FRONTEND=noninteractive apt-get update 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" >> "$LOG_FILE"

  if [[ $rc -eq 0 ]]; then
    ok "Репозиторий XanMod подключён (${found_scheme}, suite ${codename})."
    return 0
  fi

  # apt-get update возвращает ненулевой код, если СЛОМАН ЛЮБОЙ подключённый
  # репозиторий. Раньше это списывалось на XanMod, хотя ругаться мог чужой
  # .list, оставшийся на сервере. Смотрим, упоминается ли в ошибках именно
  # deb.xanmod.org, и только тогда отказываемся от репозитория.
  if grep -qi 'deb\.xanmod\.org' <<< "$out"; then
    warn "Репозиторий XanMod подключён, но apt его не принял (см. $LOG_FILE). Пропускаю ядро из APT."
    rm -f "$XANMOD_REPO_LIST"
    env DEBIAN_FRONTEND=noninteractive apt-get update >> "$LOG_FILE" 2>&1 || true
    return 1
  fi

  warn "apt-get update ругается на ДРУГОЙ репозиторий (не XanMod) — XanMod оставляю подключённым."
  ok "Репозиторий XanMod подключён (${found_scheme}, suite ${codename})."
  return 0
}

# Делает установленное ядро XanMod ($1 = uname-версия, напр. 7.1.4-x64v3-xanmod1)
# ЗАГРУЗОЧНЫМ ПО УМОЛЧАНИЮ в GRUB. Без этого после reboot сервер у ряда
# провайдеров снова грузится в дистрибутивное ядро (напр. 6.8.0-generic), а не
# в XanMod — тогда BBR3 не активен, хотя ядро установлено. Прописываем точный
# menuentry_id_option нашего ядра (учитывая вложенность в подменю "Advanced
# options") в GRUB_DEFAULT и пересобираем grub.cfg. Возвращает 0 при успехе.
set_grub_default_to_kernel() {
  local kver="$1"
  local grubdef="/etc/default/grub"
  local grubcfg="" cand eid subid target

  [[ -n "$kver" ]] || return 1

  for cand in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
    [[ -f "$cand" ]] && { grubcfg="$cand"; break; }
  done
  [[ -n "$grubcfg" && -f "$grubdef" ]] || return 1

  # menuentry_id_option нужного ядра (первое совпадение — обычный пункт, не
  # recovery). Каждый menuentry в grub.cfg — одна строка, поэтому grep -oP \K
  # с одной строки корректно достаёт id.
  eid="$(grep -oP "menuentry '[^']*${kver}[^']*'.*?menuentry_id_option '\K[^']+" "$grubcfg" 2>/dev/null | head -n1)"
  # id подменю "Advanced options for ..." (там лежат все версии ядер).
  subid="$(grep -oP "submenu '.*?'.*?menuentry_id_option '\K[^']+" "$grubcfg" 2>/dev/null | head -n1)"

  [[ -n "$eid" ]] || return 1

  if [[ -n "$subid" ]]; then
    target="${subid}>${eid}"
  else
    target="$eid"
  fi

  if grep -q '^GRUB_DEFAULT=' "$grubdef"; then
    sed -i 's~^GRUB_DEFAULT=.*~GRUB_DEFAULT="'"$target"'"~' "$grubdef"
  else
    printf 'GRUB_DEFAULT="%s"\n' "$target" >> "$grubdef"
  fi
  log_line "GRUB default set to: $target (kernel $kver)"

  if run_cmd "Делаю ядро XanMod загрузочным по умолчанию (GRUB)" update-grub; then
    ok "Ядро XanMod ($kver) выставлено загрузочным по умолчанию."
    return 0
  fi
  return 1
}

# Fallback-установка ядра XanMod напрямую с зеркала SourceForge (официальный
# бинарный релиз-хостинг XanMod), когда APT-репозиторий deb.xanmod.org
# недоступен (сейчас он стабильно отдаёт 404 на файл Release — это не
# блокировка по IP сервера, а сломанный репозиторий на их стороне).
#
# Берём RSS со списком файлов ветки main, отбираем linux-image нужной
# микроархитектуры (x64v2/x64v3, amd64), сортируем по версии ядра (sort -V) и
# ставим самую свежую через apt (apt сам подтянет зависимости из репозиториев
# дистрибутива). $1 — CPU level (v2/v3/v4). Возвращает 0 при успехе.
XANMOD_SF_RSS_URL="https://sourceforge.net/projects/xanmod/rss?path=/releases/main"

install_xanmod_from_sourceforge() {
  local cpu_level="$1"
  local variant rss url kver tmpdeb

  case "$cpu_level" in
    v4|v3) variant="x64v3" ;;
    v2)    variant="x64v2" ;;
    *) return 1 ;;
  esac

  info "APT-репозиторий XanMod недоступен — беру ядро с зеркала SourceForge ($variant)."

  rss="$(curl -fsSL --connect-timeout 10 --max-time 90 $CURL_RETRY_ALL_ERRORS_FLAG "$XANMOD_SF_RSS_URL" 2>/dev/null || true)"
  if [[ -z "$rss" ]]; then
    warn "Не удалось получить список файлов XanMod с SourceForge (нет сети/зеркало недоступно)."
    return 1
  fi

  # Отбираем ссылки на linux-image нужной микроархитектуры и выбираем самую
  # свежую по версии ядра. RSS отдаёт файлы в произвольном порядке, поэтому
  # НЕ полагаемся на head/tail, а сортируем по версии (sort -V).
  url="$(printf '%s\n' "$rss" \
    | grep -oE 'https://sourceforge\.net/projects/xanmod/files/releases/main/[^<]+/download' \
    | grep -F -- '-image-' \
    | grep -F -- "-${variant}-xanmod1_" \
    | grep -F -- '_amd64.deb/download' \
    | while IFS= read -r u; do
        v="${u##*/linux-image-}"
        v="${v%%-${variant}-xanmod1_*}"
        printf '%s\t%s\n' "$v" "$u"
      done \
    | sort -V | tail -n1 | cut -f2-)"

  if [[ -z "$url" ]]; then
    warn "На SourceForge не нашёл .deb linux-image XanMod для $variant."
    return 1
  fi

  # uname-версия ядра: часть между 'linux-image-' и первым '_'.
  kver="$(printf '%s' "$url" | sed -E 's~.*/linux-image-([^_]+)_.*~\1~')"
  ok "Самое свежее ядро XanMod на SourceForge: ${kver:-неизвестно}"

  tmpdeb="$(mktemp --suffix=.deb 2>/dev/null || mktemp)"
  info "SourceForge отдаёт файл через случайное зеркало — скорость сильно зависит от того, какое досталось."
  if ! run_download "Скачиваю ядро XanMod с SourceForge ($kver)" "$tmpdeb" "$url" \
    --connect-timeout 15 --max-time 900; then
    rm -f "$tmpdeb"
    warn "Не удалось скачать .deb ядра с SourceForge."
    return 1
  fi

  # Убеждаемся, что это действительно .deb, а не HTML-страница ошибки зеркала.
  if command -v file >/dev/null 2>&1 && ! file "$tmpdeb" 2>/dev/null | grep -qi 'Debian binary package'; then
    warn "Скачанный с SourceForge файл не похож на .deb (зеркало отдало заглушку). Пропускаю."
    rm -f "$tmpdeb"
    return 1
  fi

  if ! run_cmd "Устанавливаю ядро XanMod из .deb" \
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$tmpdeb"; then
    rm -f "$tmpdeb"
    warn "Не удалось установить ядро XanMod из .deb (apt)."
    return 1
  fi
  rm -f "$tmpdeb"

  KERNEL_VER="$(highest_installed_xanmod)"
  [[ -n "$KERNEL_VER" ]] || KERNEL_VER="$kver"
  if [[ -n "$KERNEL_VER" ]]; then
    mkdir -p "$STATE_DIR"
    echo "$KERNEL_VER" > "$KERNEL_VER_FILE"
    ok "Установлена версия ядра XanMod (SourceForge): $KERNEL_VER"
  fi

  run_cmd "Обновляю GRUB" update-grub || warn "update-grub вернул ошибку — проверь загрузчик вручную."
  set_grub_default_to_kernel "$KERNEL_VER" \
    || warn "Не удалось выставить ядро XanMod дефолтным в GRUB — если после reboot загрузится старое ядро, выбери XanMod в меню GRUB (Advanced options)."
  KERNEL_INSTALL_SKIPPED=0
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
    warn "Официальный APT-репозиторий XanMod (deb.xanmod.org) недоступен."
    if install_xanmod_from_sourceforge "$CPU_LEVEL"; then
      return 0
    fi
    KERNEL_INSTALL_SKIPPED=1
    warn "Не удалось получить ядро XanMod ни из APT-репозитория, ни с зеркала SourceForge — продолжаю без нового ядра."
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
  if [[ -n "$KERNEL_VER" ]]; then
    set_grub_default_to_kernel "$KERNEL_VER" \
      || warn "Не удалось выставить ядро XanMod дефолтным в GRUB — если после reboot загрузится старое ядро, выбери XanMod в меню GRUB (Advanced options)."
  fi
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

net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 65535
net.core.rps_sock_flow_entries = 32768

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

# Поднимает системные лимиты файловых дескрипторов и процессов до 1048576 на
# уровне ОС (limits.conf + systemd), чтобы xray/docker и всё дерево процессов
# ноды не упирались в дефолтные 1024/недостаточный потолок под нагрузкой.
# Идея и значения взяты из node-accelerator. В контейнере (LXC/OpenVZ) потолок
# задаёт хост — тогда просто пишем конфиги (применятся, где разрешено), а не
# валимся. Эффект для интерактивных сессий — после повторного входа/reboot; для
# systemd-сервисов (docker) — после systemctl daemon-reexec + рестарта сервиса.
apply_system_limits() {
  section "Системные лимиты (nofile/nproc)"

  local limit=1048576

  # PAM limits для интерактивных сессий и сервисов, использующих pam_limits.
  cat >/etc/security/limits.d/99-eclipse.conf <<EOF_LIMITS
*     soft nofile $limit
*     hard nofile $limit
*     soft nproc  $limit
*     hard nproc  $limit
root  soft nofile $limit
root  hard nofile $limit
root  soft nproc  $limit
root  hard nproc  $limit
EOF_LIMITS
  ok "Записан /etc/security/limits.d/99-eclipse.conf (nofile/nproc = $limit)"

  # systemd задаёт лимиты для сервисов (в т.ч. docker.service) через
  # DefaultLimit*. Пишем и в system.conf.d, и в user.conf.d.
  mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d

  cat >/etc/systemd/system.conf.d/99-eclipse-limits.conf <<EOF_SYSTEMD
[Manager]
DefaultLimitNOFILE=$limit
DefaultLimitNPROC=$limit
EOF_SYSTEMD

  cat >/etc/systemd/user.conf.d/99-eclipse-limits.conf <<EOF_SYSTEMD_USER
[Manager]
DefaultLimitNOFILE=$limit
DefaultLimitNPROC=$limit
EOF_SYSTEMD_USER
  ok "Записаны systemd DefaultLimitNOFILE/NPROC = $limit"

  # Убеждаемся, что pam_limits подключён (на Debian/Ubuntu обычно уже есть в
  # common-session). Не критично, если файла нет — просто пропускаем.
  local pam_f
  for pam_f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [[ -f "$pam_f" ]] || continue
    if ! grep -qE '^\s*session\s+required\s+pam_limits\.so' "$pam_f"; then
      echo "session required pam_limits.so" >> "$pam_f"
      info "Добавил pam_limits.so в $pam_f"
    fi
  done

  # Перечитываем конфиг systemd-менеджера, чтобы DefaultLimit* вступили в силу
  # для сервисов, стартующих дальше (docker поднимается позже в install_docker).
  systemctl daemon-reexec >> "$LOG_FILE" 2>&1 \
    || warn "systemctl daemon-reexec вернул ошибку (типично для ограниченного контейнера) — продолжаю."

  local cur_soft cur_hard
  cur_soft="$(ulimit -Sn 2>/dev/null || echo '?')"
  cur_hard="$(ulimit -Hn 2>/dev/null || echo '?')"
  info "Текущая сессия nofile: soft=$cur_soft hard=$cur_hard (новые значения применятся после повторного входа/reboot)."
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

TARGET_RLIMIT=1048576

# PID работающего демона docker (пусто, если не запущен). pgrep есть не везде,
# поэтому есть запасной путь через pidof.
dockerd_pid() {
  local pid

  pid="$(pgrep -x dockerd 2>/dev/null | head -n1 || true)"
  [[ -n "$pid" ]] || pid="$(pidof dockerd 2>/dev/null | awk '{print $1}' || true)"

  [[ -n "$pid" ]] || return 1
  printf '%s' "$pid"
}

# Жёсткий rlimit процесса из /proc/<pid>/limits.
# $1 = pid, $2 = имя лимита ("Max open files" / "Max processes").
# Печатает число, "unlimited" или ничего (если прочитать не удалось).
proc_hard_limit() {
  local pid="$1" name="$2" line rest

  [[ -r "/proc/$pid/limits" ]] || return 1

  line="$(grep -m1 "^${name}[[:space:]]" "/proc/$pid/limits" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1

  # После имени лимита идут: soft, hard, [units]. Имя содержит пробелы, поэтому
  # отрезаем его как префикс, а не считаем поля с начала строки.
  rest="${line#"$name"}"
  # shellcheck disable=SC2086
  set -- $rest

  [[ -n "${2:-}" ]] || return 1
  printf '%s' "$2"
}

# Потолок rlimit, который runc РЕАЛЬНО сможет выставить контейнеру.
# $1 = nofile | nproc.
#
# Зачем: runc не может поднять лимит выше жёсткого лимита процесса-родителя, а
# родитель здесь — демон docker (его наследуют containerd-shim и runc). Если
# в docker-compose.yml написать больше, контейнер не стартует вовсе:
#   error setting rlimit type 7: operation not permitted   (7 = RLIMIT_NOFILE)
# Смотреть `ulimit -Hn` текущей оболочки для этого бессмысленно — у демона свои
# лимиты из его systemd-юнита. Плюс для NOFILE есть жёсткий потолок ядра
# fs.nr_open, выше которого setrlimit не пройдёт ни у кого.
container_rlimit_ceiling() {
  local kind="$1"
  local best="$TARGET_RLIMIT"
  local name shell_cap pid val nr_open

  case "$kind" in
    nofile) name="Max open files"; shell_cap="$(ulimit -Hn 2>/dev/null || true)" ;;
    nproc)  name="Max processes";  shell_cap="$(ulimit -Hu 2>/dev/null || true)" ;;
    *) echo "$best"; return 0 ;;
  esac

  val=""
  pid="$(dockerd_pid || true)"
  [[ -n "$pid" ]] && val="$(proc_hard_limit "$pid" "$name" || true)"

  # Демон не найден, или его /proc/<pid>/limits не разобрался (иной PID-namespace,
  # урезанный /proc) — падаем на лимит текущей оболочки: она тоже потомок systemd
  # с теми же DefaultLimit*. Без этого мы бы молча оставили целевые 1048576 на
  # хосте, где реальный потолок втрое ниже, — то есть ровно тот EPERM, ради
  # которого вся эта функция и написана. "unlimited" сюда тоже попадает и
  # корректно не проходит числовую проверку ниже.
  [[ "$val" =~ ^[0-9]+$ ]] || val="$shell_cap"

  [[ "$val" =~ ^[0-9]+$ ]] && (( val < best )) && best="$val"

  if [[ "$kind" == "nofile" ]]; then
    nr_open="$(sysctl -n fs.nr_open 2>/dev/null || true)"
    [[ "$nr_open" =~ ^[0-9]+$ ]] && (( nr_open < best )) && best="$nr_open"
  fi

  echo "$best"
}

# Поднимает лимиты САМОГО демона docker через drop-in его юнита. Без этого
# потолок демона (а значит и всех контейнеров) остаётся тем, что дал дистрибутив
# — а пакет docker.io из репозитория Ubuntu приезжает с куда более скромными
# значениями, чем docker-ce. Особенно важно в режиме «только нода»: там
# apply_system_limits не выполняется, и поднять DefaultLimit* systemd больше некому.
#
# LimitNOFILE пишем ЧИСЛОМ, равным fs.nr_open, а не `infinity`. `infinity`
# безопасен только на systemd >= 240, который сам приводит его к fs.nr_open;
# на более старом (Ubuntu 18.04 — systemd 237) значение уходит в setrlimit как
# есть, ядро отвечает EPERM, и docker.service перестаёт стартовать вообще.
# Если fs.nr_open прочитать не удалось — LimitNOFILE не трогаем совсем.
DOCKER_LIMITS_DROPIN="/etc/systemd/system/docker.service.d/99-eclipse-limits.conf"

raise_docker_service_limits() {
  local nr_open nofile_line=""

  nr_open="$(sysctl -n fs.nr_open 2>/dev/null || true)"
  [[ "$nr_open" =~ ^[0-9]+$ ]] && nofile_line="LimitNOFILE=$nr_open"

  mkdir -p "$(dirname "$DOCKER_LIMITS_DROPIN")"

  cat >"$DOCKER_LIMITS_DROPIN" <<EOF_DOCKERLIM
[Service]
$nofile_line
LimitNPROC=infinity
EOF_DOCKERLIM

  systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
}

# Перезапуск docker после установки drop-in. Если юнит из-за него не поднялся,
# drop-in снимаем и поднимаем docker обратно: остаться без docker хуже, чем
# остаться с дистрибутивными лимитами (их всё равно учтёт container_rlimit_ceiling).
restart_docker_with_limits() {
  if run_cmd "Перезапускаю Docker (новые лимиты юнита)" systemctl restart docker; then
    return 0
  fi

  warn "Docker не стартовал с поднятыми лимитами — откатываю drop-in $DOCKER_LIMITS_DROPIN."
  rm -f "$DOCKER_LIMITS_DROPIN"
  systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true

  run_cmd "Перезапускаю Docker (без drop-in)" systemctl restart docker
}

install_docker() {
  section "7/12 · Docker"

  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен"
  else
    install_docker_engine
  fi

  mkdir -p /etc/docker

  # Порядок здесь важен. Сначала поднимаем лимиты САМОГО демона и
  # перезапускаем его — иначе потолок пришлось бы считать по старому процессу
  # dockerd и мы записали бы в daemon.json заниженные значения.
  raise_docker_service_limits
  run_cmd "Включаю Docker" systemctl enable docker
  restart_docker_with_limits

  local docker_nofile_limit docker_nproc_limit
  docker_nofile_limit="$(container_rlimit_ceiling nofile)"
  docker_nproc_limit="$(container_rlimit_ceiling nproc)"

  if (( docker_nofile_limit < TARGET_RLIMIT || docker_nproc_limit < TARGET_RLIMIT )); then
    info "Потолок этого окружения ниже целевого ($TARGET_RLIMIT): nofile=$docker_nofile_limit, nproc=$docker_nproc_limit. Беру достижимое — выше runc всё равно не даст."
  fi

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

  run_cmd "Перезапускаю Docker (default-ulimits)" systemctl restart docker

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

  if ! run_live_cancellable "Запускаю iperf3 speedtest (RU)" \
    "bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)" 60; then
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
  ask ans "  Выбор [1/2/3/0]: "

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
  info "Selfsteal поднимает на этом же сервере Caddy-заглушку под твоим доменом —"
  info "REALITY маскируется под неё (target = 127.0.0.1). Без selfsteal REALITY"
  info "маскируется под чужой реальный сайт (borrowed SNI, напр. www.samsung.com)."
  echo
  ask ans "  Запустить selfsteal.sh сейчас? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да)
      if run_shell_live "Запускаю selfsteal.sh" "bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh)"; then
        ok "Selfsteal завершён, продолжаю установку ноды."
      else
        warn "Selfsteal.sh вернул ненулевой код (это может быть нормально для его собственной логики). Продолжаю установку ноды — её настройка дальше не зависит от selfsteal."
      fi
      SELFSTEAL_ENABLED=1
      ;;
    *)
      SELFSTEAL_ENABLED=0
      ok "Selfsteal пропущен — REALITY будет маскироваться под внешний домен (SNI спросим ниже)."
      ;;
  esac
}

ask_domain() {
  local input=""

  while true; do
    ask input "  Домен для сертификата (например, node.example.com): "
    input="$(echo "${input:-}" | tr -d '[:space:]')"

    if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      DOMAIN="$input"
      ok "Домен: $DOMAIN"
      return 0
    fi

    warn "Некорректный домен. Пример: node.example.com"
  done
}

# Считает количество A-записей домена (через публичные резолверы). >=2 —
# это round-robin / DNS-балансировка, при которой HTTP-01 challenge не проходит.
count_domain_a_records() {
  local domain="$1" n=0

  command -v dig >/dev/null 2>&1 || { echo 0; return 0; }

  n="$(dig +short A "$domain" @8.8.8.8 2>/dev/null | grep -Ec '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0

  if [[ "$n" -eq 0 ]]; then
    n="$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -Ec '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
  fi

  echo "$n"
}

# Выпускает сертификат через DNS-01 с ручной TXT-записью (для доменов с
# несколькими IP / DNS-балансировкой, где HTTP-01 невозможен). certbot через
# auth-hook показывает нужную TXT-запись; hook сам ждёт, пока именно это
# значение начнёт отдаваться публичными DNS, и только тогда даёт LE проверять.
# Заполняет CERT_DIR / CERT_OK.
issue_cert_dns01_manual() {
  local domain="$1"
  local hook="$STATE_DIR/certbot-dns-auth-hook.sh"
  local rc

  mkdir -p "$STATE_DIR"

  cat > "$hook" <<'EOF_AUTHHOOK'
#!/usr/bin/env bash
# certbot manual auth-hook (DNS-01): печатает TXT-запись, которую нужно
# добавить, и ждёт, пока ИМЕННО это значение начнёт отдаваться. Ждёт запись на
# ВСЕХ авторитетных NS зоны (reg.ru обычно имеет ns1+ns2): Let's Encrypt при
# проверке опрашивает случайный из них, поэтому если запись есть только на
# одном — LE может получить NXDOMAIN. Публичные резолверы — только запасной
# вариант, когда авторитетные NS определить не удалось.
set -u

DOMAIN="${CERTBOT_DOMAIN:?}"
VALIDATION="${CERTBOT_VALIDATION:?}"
RECORD="_acme-challenge.${DOMAIN}"

out() { printf '%s\n' "$*" > /dev/tty 2>/dev/null || printf '%s\n' "$*"; }

# Быстрый dig: короткий таймаут, чтобы «молчащие»/перехваченные резолверы
# не подвешивали проверку.
DIG="dig +short +time=3 +tries=1"

# Возвращает ВСЕ авторитетные NS зоны (по одному на строку), поднимаясь от
# полного имени к корню (de34.safeeclipse.online → safeeclipse.online → ...).
find_auth_ns_all() {
  local name="$1" nslist
  while [[ "$name" == *.* ]]; do
    nslist="$($DIG NS "$name" 2>/dev/null | sed 's/\.$//' | sort -u)"
    [[ -n "$nslist" ]] && { printf '%s\n' "$nslist"; return 0; }
    name="${name#*.}"
  done
  return 1
}

# Проверяет TXT на конкретном сервере (пусто = системный резолвер).
check_at() {
  local server="${1:-}" got
  if [[ -n "$server" ]]; then
    got="$($DIG TXT "$RECORD" "@$server" 2>/dev/null | tr -d '"')"
  else
    got="$($DIG TXT "$RECORD" 2>/dev/null | tr -d '"')"
  fi
  grep -qxF "$VALIDATION" <<< "$got"
}

mapfile -t AUTH_NS < <(find_auth_ns_all "$DOMAIN" || true)
RESOLVERS=(1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8)

# Все авторитетные NS должны отдавать запись.
all_auth_have() {
  local ns
  [[ ${#AUTH_NS[@]} -gt 0 ]] || return 1
  for ns in "${AUTH_NS[@]}"; do
    check_at "$ns" || return 1
  done
  return 0
}

# Сколько NS уже отдают (для прогресса).
auth_have_count() {
  local ns c=0
  for ns in "${AUTH_NS[@]}"; do
    check_at "$ns" && c=$((c + 1))
  done
  echo "$c"
}

out ""
out "════════════════════════════════════════════════════════════"
out "  DNS-01: добавь TXT-запись у регистратора (reg.ru):"
out ""
out "    Тип:      TXT"
out "    Имя/Host: ${RECORD%.*.*}      (в зоне это часть до основного домена)"
out "    Значение: ${VALIDATION}"
out ""
out "  Полное имя записи: ${RECORD}"
out "════════════════════════════════════════════════════════════"
if [[ ${#AUTH_NS[@]} -gt 0 ]]; then
  out "  Авторитетные NS зоны (ждём запись на ВСЕХ): ${AUTH_NS[*]}"
fi
out "  Как добавишь — скрипт сам увидит запись и продолжит."
out ""

MAX=120   # 120 * 10s = 20 минут
i=0
while (( i < MAX )); do
  if [[ ${#AUTH_NS[@]} -gt 0 ]]; then
    # Ждём запись на ВСЕХ авторитетных NS — иначе LE может попасть на тот,
    # где её ещё нет, и вернуть NXDOMAIN.
    if all_auth_have; then
      printf '\r%*s\r' 70 '' > /dev/tty 2>/dev/null || true
      out "  [OK] TXT видна на всех авторитетных NS (${#AUTH_NS[@]}). Жду 15с для надёжности и продолжаю."
      sleep 15
      exit 0
    fi
  else
    # NS не определили — опираемся на публичные резолверы (минимум 2).
    ok_count=0
    for r in "${RESOLVERS[@]}"; do
      check_at "$r" && ok_count=$((ok_count + 1))
    done
    if (( ok_count >= 2 )); then
      printf '\r%*s\r' 70 '' > /dev/tty 2>/dev/null || true
      out "  [OK] TXT видна в публичных DNS (${ok_count}). Жду 15с и продолжаю."
      sleep 15
      exit 0
    fi
  fi

  i=$((i + 1))
  if [[ ${#AUTH_NS[@]} -gt 0 ]]; then
    printf '\r  Ожидаю TXT на NS: %s/%d... попытка %d/%d   ' "$(auth_have_count)" "${#AUTH_NS[@]}" "$i" "$MAX" > /dev/tty 2>/dev/null || true
  else
    printf '\r  Ожидаю распространения TXT... попытка %d/%d   ' "$i" "$MAX" > /dev/tty 2>/dev/null || true
  fi
  sleep 10
done

out ""
out "  [WARN] За 20 минут TXT так и не появилась на всех NS."
printf '  Продолжить валидацию всё равно? [y/N]: ' > /dev/tty 2>/dev/null || true
read -r ans < /dev/tty 2>/dev/null || ans="n"
case "${ans,,}" in y|yes|д|да) exit 0 ;; *) exit 1 ;; esac
EOF_AUTHHOOK

  chmod +x "$hook"

  section "DNS-01 (TXT) для $domain"
  info "У домена несколько IP (DNS-балансировка) — выпускаю сертификат через DNS-01."
  info "certbot покажет TXT-запись, добавь её в reg.ru; скрипт дождётся распространения и продолжит."
  echo

  CERT_OK=0
  set +e
  certbot certonly --manual --preferred-challenges dns \
    --manual-auth-hook "$hook" \
    --non-interactive --agree-tos \
    --register-unsafely-without-email \
    -d "$domain" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" -eq 0 && -f "/etc/letsencrypt/live/$domain/fullchain.pem" && -f "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
    CERT_DIR="/etc/letsencrypt/live/$domain"
    CERT_OK=1
    ok "Сертификат (DNS-01) успешно выпущен: $CERT_DIR"
    warn "Внимание: DNS-01 с ручной TXT не продлевается автоматически — при DNS-балансировке LE даёт новое значение TXT."
    warn "Перед истечением (~каждые 60-90 дней) перевыпусти сертификат: eclipse (пункт установки TLS) или certbot renew с добавлением новой TXT."
  else
    fail "Не удалось выпустить сертификат через DNS-01 для $domain (rc=$rc)."
  fi
}

issue_tls_certificate() {
  section "11/12 · TLS сертификат"

  if ! command -v certbot >/dev/null 2>&1; then
    run_cmd "Устанавливаю certbot" env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y certbot
  fi

  # Если скрипт запускают повторно (например, после сбоя запуска ноды) и для
  # ранее сохранённого домена уже есть действующий сертификат — предлагаем его
  # переиспользовать, но НЕ навязываем: пользователь может захотеть другой
  # домен/сертификат, поэтому спрашиваем, а не возвращаемся молча.
  local declined_saved=0
  if [[ -f "$DOMAIN_FILE" ]]; then
    local saved_domain saved_ans
    saved_domain="$(cat "$DOMAIN_FILE" 2>/dev/null || true)"

    if [[ -n "$saved_domain" ]] && check_existing_certificate "$saved_domain"; then
      echo
      info "Найден действующий сертификат для сохранённого ранее домена: $saved_domain"
      ask saved_ans "  Использовать его? (n — указать другой домен/сертификат) [Y/n]: "

      case "${saved_ans,,}" in
        n|no|н|нет)
          info "Хорошо, выберем другой домен/сертификат."
          declined_saved=1
          ;;
        *)
          DOMAIN="$saved_domain"
          CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
          CERT_OK=1
          ok "Использую сертификат для домена $DOMAIN."
          return 0
          ;;
      esac
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

  if [[ "$declined_saved" -ne 1 && "$found_count" -gt 0 ]]; then
    echo
    info "На сервере уже есть действующие сертификаты Let's Encrypt:"
    echo "$found_certs" | sed 's/^/    - /'
    echo

    local reuse_ans reuse_domain
    ask reuse_ans "  Использовать один из них вместо выпуска нового? [Y/n]: "

    case "${reuse_ans,,}" in
      n|no|н|нет)
        ;;
      *)
        if [[ "$found_count" -eq 1 ]]; then
          reuse_domain="$found_certs"
        else
          ask reuse_domain "  Введи домен из списка выше: "
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
  info "Перед выпуском убедись, что A-запись домена указывает на IP этого сервера."
  info "Один IP → HTTP-01 (certbot временно займёт порт 80, он должен быть свободен)."
  info "Несколько IP (DNS-балансировка) → скрипт сам переключится на DNS-01 (TXT-запись)."
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

    CERT_OK=0

    local a_count
    a_count="$(count_domain_a_records "$DOMAIN")"

    if (( a_count >= 2 )); then
      # DNS-балансировка: несколько A-записей → HTTP-01 не пройдёт (LE
      # проверяет со всех перспектив, попадёт и на «чужой» IP). Идём DNS-01.
      warn "У домена $DOMAIN несколько A-записей ($a_count) — это DNS-балансировка."
      info "HTTP-01 (порт 80) при этом не проходит — переключаюсь на DNS-01 (TXT-запись)."
      issue_cert_dns01_manual "$DOMAIN"
    else
      run_shell "Освобождаю порт 80 (если занят nginx/apache)" \
        "systemctl stop nginx >/dev/null 2>&1 || true; systemctl stop apache2 >/dev/null 2>&1 || true; true"

      if run_cmd "Выпускаю сертификат Let's Encrypt (HTTP-01) для $DOMAIN" \
        certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email --preferred-challenges http \
        -d "$DOMAIN"; then

        if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
          CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
          CERT_OK=1
        fi
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
    ask ans "  Попробовать снова с другим доменом? [Y/n]: "

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
  ask ans "  Добавить Hysteria2 (UDP) inbound к этой ноде? [y/N]: "

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

# ============================================================================
# Torrent Guard — объединённая защита ноды от торрентов.
#
# Здесь слиты в один модуль два независимых блокера, которые решают РАЗНЫЕ
# половины задачи и поэтому дополняют друг друга:
#
#   Слой A — ds-guard (DoubleServers VPS Guard v1.6): ГЛУШИТ САМ ТРАФИК на
#     выходе с сервера.
#       L1 nDPI     — модуль ядра xt_ndpi + правило
#                     iptables -o WAN -m ndpi --proto bittorrent -j DROP
#                     (настоящая классификация протокола, не только порты)
#       L2 Suricata — IPS через NFQUEUE на исходящий UDP: DHT, uTP, UDP-трекеры,
#                     LSD BT-SEARCH, HTTP-announce/scrape, торрентовые User-Agent
#       L3 domains  — цепочка DS_DOMAINS: -m string блок домена packetsdk
#                     (абуз proxy-SDK) плюс свои домены
#       Self-heal   — systemd-таймер каждые 5 минут заново вставляет правила
#                     (их сносит перезагрузка ufw/docker), а DKMS пересобирает
#                     модуль ядра после его обновления.
#     Вендор раздаёт этот слой как shc-бинарник (закрытый). Его исходник
#     распакован и вшит в скрипт целиком (tg_write_guard_script) — ничего
#     закрытого с чужого хоста больше не скачивается и не запускается от root.
#
#   Слой B — torrent-blocker (Go, mahmudali1337-lab): БАНИТ КЛИЕНТА, который
#     торрентит. Читает access.log xray по тегу TORRENT, плюс эвристики по
#     netstat (шторм FIN_WAIT, много ESTABLISHED с большой send-queue). Банит IP
#     клиента и IP пиров/трекеров (ipset auto_peers/auto_trackers, цепочки
#     TORRENT_DPI / TORRENT_BAN / TORRENT_PEERS).
#
# Конфликта цепочек между слоями нет — у каждого свои. Оба вставляют правила в
# начало OUTPUT, и это нормально: порядок DROP'ов между собой не важен.
#
# Отличия вшитого слоя A от вендорского бинарника (помечены "# [eclipse]"):
#   - читает настройки из $TG_CONFIG, чтобы выбор в меню жил после перезагрузки;
#   - Suricata (L2) выключается отдельно от nDPI (L1): на Hysteria2-нодах весь
#     исходящий UDP через NFQUEUE — заметная нагрузка, иногда её лучше не платить.
# ============================================================================

TG_DIR="/etc/ds-guard"
TG_CONFIG="$TG_DIR/config"
TG_SCRIPT="/usr/local/sbin/eclipse-torrent-guard.sh"
TG_LOG="/var/log/ds-guard-install.log"

# ── Слой B: почему netstat-эвристики выключены по умолчанию ─────────────────
#
# У Go-блокера есть два независимых источника решений:
#
#   1) РЕАЛЬНЫЙ детект торрентов — разбор access.log xray по тегу TORRENT
#      (его ставит routing-правило ноды) и по совпадениям DPI. Это то, что нам
#      нужно: банится тот, кто действительно качал торрент.
#
#   2) Эвристики по netstat — «много ESTABLISHED с одного IP» и «шторм
#      FIN_WAIT». Это НЕ детект торрентов: признак чисто количественный.
#      Мост/релей/вторая нода, которая гонит через этот сервер трафик, легко
#      даёт 400+ соединений и попадает под бан с причиной
#      multi_conn_large_sendq — при том, что торрентов там нет вообще.
#      Поэтому TB_NETSTAT=0 по умолчанию.
#
# Вторая мина вендорского инсталлятора: он прописывает
# --log /var/log/remnanode/access.log — это путь ВНУТРИ контейнера. На хосте
# логи ноды лежат в <папка ноды>/logs/access.log (compose монтирует
# ./logs:/var/log/remnanode). С неверным путём разбор логов молчит, и
# единственным работающим механизмом остаётся именно эвристика из п.2 —
# то есть блокер банит только своих. tb_detect_access_log определяет
# настоящий путь на хосте.

# Настройки слоёв (перезаписываются из $TG_CONFIG).
TG_TORRENT=1
TG_SURICATA=1
TG_PACKETSDK=1

# Слой B (torrent-blocker).
TB_NETSTAT=0            # 1 — включить эвристики по числу соединений (см. выше)
TB_BYPASS=""            # белый список IP: мосты, релеи, свои сервисы
TB_CONN_THRESH=1000     # порог ESTABLISHED (действует только при TB_NETSTAT=1)
TB_SENDQ_THRESH=50      # порог соединений с большой send-queue
TB_BAN_DURATION=10      # минут бана
TB_UNIT="/etc/systemd/system/torrent-blocker.service"
TG_DOMAINS=""

is_torrent_blocker_installed() {
  [[ -x "$TORRENT_BLOCKER_BIN" ]]
}

tg_guard_installed() {
  [[ -x "$TG_SCRIPT" ]]
}

tg_load_config() {
  [[ -r "$TG_CONFIG" ]] || return 0

  # Локальные — чтобы значения из файла не оставались глобальными и не
  # перебивали то, что пользователь только что переключил в меню настроек.
  local DS_TORRENT DS_SURICATA DS_PACKETSDK DS_DOMAINS
  local TB_NETSTAT_F TB_BYPASS_F TB_CONN_F TB_SENDQ_F TB_BAN_F
  # shellcheck disable=SC1090
  source "$TG_CONFIG" 2>/dev/null || return 0

  TG_TORRENT="${DS_TORRENT:-$TG_TORRENT}"
  TG_SURICATA="${DS_SURICATA:-$TG_SURICATA}"
  TG_PACKETSDK="${DS_PACKETSDK:-$TG_PACKETSDK}"
  TG_DOMAINS="${DS_DOMAINS:-$TG_DOMAINS}"

  # TB_* приходят из того же файла напрямую (имена совпадают), поэтому здесь
  # только подставляем дефолты, если ключа в файле не было.
  TB_NETSTAT="${TB_NETSTAT:-0}"
  TB_BYPASS="${TB_BYPASS:-}"
  TB_CONN_THRESH="${TB_CONN_THRESH:-1000}"
  TB_SENDQ_THRESH="${TB_SENDQ_THRESH:-50}"
  TB_BAN_DURATION="${TB_BAN_DURATION:-10}"
}

tg_save_config() {
  mkdir -p "$TG_DIR"
  cat > "$TG_CONFIG" <<CFG
# Настройки Torrent Guard. Файл читают и сам guard-скрипт, и Eclipse Node Manager.

# Слой A (ds-guard): DPI-глушение трафика.
DS_TORRENT=$TG_TORRENT
DS_SURICATA=$TG_SURICATA
DS_PACKETSDK=$TG_PACKETSDK
DS_DOMAINS="$TG_DOMAINS"

# Слой B (torrent-blocker): бан клиента.
# TB_NETSTAT=1 включает эвристики по ЧИСЛУ соединений — они не отличают торрент
# от моста/релея и умеют банить свою же инфраструктуру. Держи 0, если через
# сервер ходят мосты или другие ноды.
TB_NETSTAT=$TB_NETSTAT
TB_BYPASS="$TB_BYPASS"
TB_CONN_THRESH=$TB_CONN_THRESH
TB_SENDQ_THRESH=$TB_SENDQ_THRESH
TB_BAN_DURATION=$TB_BAN_DURATION
CFG
  chmod 600 "$TG_CONFIG"
}

# ── Ротация логов ───────────────────────────────────────────────────────────
#
# Как только в конфиге ноды включён access.log (а он нужен слою B, чтобы видеть
# торрент-трафик по тегу TORRENT), лог начинает расти быстро: на нагруженной
# ноде это десятки МБ в сутки. Без ротации он рано или поздно съест диск.
#
# copytruncate здесь принципиален: xray держит файл открытым и не переоткрывает
# его по сигналу. При обычной ротации (переименование) xray продолжил бы писать
# в переименованный inode, и новый access.log остался бы пустым — то есть слой B
# ослеп бы после первой же ротации. copytruncate копирует содержимое и обрезает
# исходный файл на месте, дескриптор остаётся валидным.
#
# maxsize вместе с daily даёт «раз в сутки ИЛИ при превышении размера» — защита
# от того, что за одни сутки лог распухнет сильнее, чем есть места на диске.

ECLIPSE_LOGROTATE="/etc/logrotate.d/eclipse-node"

ensure_logrotate() {
  command -v logrotate >/dev/null 2>&1 && return 0
  run_cmd "Устанавливаю logrotate" env DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate
}

install_log_rotation() {
  section "Ротация логов (раз в сутки)"

  if ! ensure_logrotate; then
    warn "logrotate не установлен — ротация не настроена."
    return 1
  fi

  # Пути нод перечислены шаблонами: одна конфигурация покрывает все варианты
  # размещения (/opt/remnanode, /root/remnanode, /home/<user>/remnanode, ...).
  cat > "$ECLIPSE_LOGROTATE" <<'ROTATE'
# Логи Remnawave Node (access.log / error.log от xray).
# copytruncate — xray держит файл открытым и не переоткрывает его по сигналу.
/opt/remnanode/logs/*.log
/root/remnanode/logs/*.log
/home/*/remnanode/logs/*.log
/opt/*-Node/logs/*.log
{
    daily
    rotate 7
    maxsize 200M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
    su root root
}

# Логи самого менеджера и анти-торрент слоя A.
/var/log/bbr3-remnanode-install.log
/var/log/ds-guard-install.log
/var/log/warp-auto-install.log
{
    daily
    rotate 14
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
ROTATE

  chmod 644 "$ECLIPSE_LOGROTATE"
  ok "Конфигурация ротации записана: $ECLIPSE_LOGROTATE"

  # Проверяем синтаксис в режиме отладки (ничего не ротируя).
  if logrotate --debug "$ECLIPSE_LOGROTATE" >> "$LOG_FILE" 2>&1; then
    ok "Конфигурация logrotate прошла проверку (--debug)."
  else
    warn "logrotate --debug вернул ошибку. Подробности: $LOG_FILE"
  fi

  # На Debian/Ubuntu ротацию запускает системный таймер logrotate.timer
  # (или cron.daily на старых релизах) — свой таймер не нужен, только убедимся,
  # что штатный включён.
  if systemctl list-unit-files 2>/dev/null | grep -q '^logrotate.timer'; then
    systemctl enable --now logrotate.timer >> "$LOG_FILE" 2>&1 || true
    info "Запуск ротации: logrotate.timer ($(systemctl is-active logrotate.timer 2>/dev/null || echo inactive))"
  elif [[ -d /etc/cron.daily ]]; then
    info "Запуск ротации: /etc/cron.daily/logrotate"
  else
    warn "Не нашёл ни logrotate.timer, ни /etc/cron.daily — ротацию нужно запускать самому."
  fi

  echo
  info "Хранится: логи ноды 7 суток, логи менеджера 14 суток, сжатие включено."
  info "Проверить вручную, ничего не меняя: logrotate --debug $ECLIPSE_LOGROTATE"
  info "Прогнать принудительно: logrotate --force $ECLIPSE_LOGROTATE"
}

# ── Слой B: путь к логу, белый список, свой systemd-юнит ────────────────────

# Печатает путь к access.log ноды НА ХОСТЕ. Compose монтирует ./logs в
# /var/log/remnanode внутри контейнера, поэтому вендорский дефолт
# /var/log/remnanode/access.log на хосте обычно не существует.
tb_detect_access_log() {
  local d

  d="$(find_node_dir || true)"
  if [[ -n "$d" && -d "$d/logs" ]]; then
    echo "$d/logs/access.log"
    return 0
  fi

  for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
    [[ -f "$d/logs/access.log" ]] && { echo "$d/logs/access.log"; return 0; }
  done

  # Фоллбэк: вендорский путь (верен, только если логи реально лежат на хосте там).
  echo "/var/log/remnanode/access.log"
}

# Печатает итоговый белый список IP для --bypass (через запятую):
# localhost + IP панели + IP текущей SSH-сессии + то, что добавил пользователь.
# Панель и своя SSH-сессия — чтобы блокер физически не мог отрезать управление.
tb_build_bypass() {
  local ips=("127.0.0.1" "::1") ip panel_domain

  # 2>/dev/null ДО `<`: иначе отсутствие файла печатает ошибку в терминал
  # (перенаправления обрабатываются слева направо).
  panel_domain="$(tr -d '[:space:]' 2>/dev/null < "$ECLIPSE_PANEL_DOMAIN_FILE" || true)"
  if [[ -n "$panel_domain" ]]; then
    for ip in $(na_resolve_domain_v4 "$panel_domain" 2>/dev/null || true); do
      ips+=("$ip")
    done
    for ip in $(na_resolve_domain_v6 "$panel_domain" 2>/dev/null || true); do
      ips+=("$ip")
    done
  fi

  for ip in $(na_detect_ssh_client_ip 2>/dev/null || true); do
    ips+=("$ip")
  done

  for ip in $TB_BYPASS; do
    ips+=("$ip")
  done

  printf '%s\n' "${ips[@]}" | awk 'NF' | sort -u | paste -sd, -
}

# Пишет СВОЙ systemd-юнит для torrent-blocker вместо вендорского: правильный
# путь к логу, белый список и netstat-эвристики по нашему конфигу.
tb_write_unit() {
  local logpath bypass netstat_flags

  logpath="$(tb_detect_access_log)"
  bypass="$(tb_build_bypass)"

  if [[ "$TB_NETSTAT" == "1" ]]; then
    # Эвристики включены осознанно — оставляем только вариант conns+sendq,
    # шторм FIN_WAIT отключён (он ложно срабатывает ещё чаще).
    netstat_flags="--no-finwait-ban --conn-thresh $TB_CONN_THRESH --sendq-thresh $TB_SENDQ_THRESH"
  else
    # --no-netstat полностью убирает решения по числу соединений. Остаётся
    # разбор access.log по тегу TORRENT и DPI — то есть только торренты.
    netstat_flags="--no-netstat --no-finwait-ban"
  fi

  cat > "$TB_UNIT" <<UNIT
[Unit]
Description=Torrent Blocker (Eclipse Torrent Guard, слой B)
After=network.target

[Service]
Type=simple
ExecStart=$TORRENT_BLOCKER_BIN --log $logpath --tag TORRENT --ban-duration $TB_BAN_DURATION --bypass $bypass $netstat_flags
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  ok "Юнит torrent-blocker перезаписан под ноду:"
  info "лог: $logpath"
  info "белый список: $bypass"
  if [[ "$TB_NETSTAT" == "1" ]]; then
    warn "netstat-эвристики ВКЛЮЧЕНЫ (conn>$TB_CONN_THRESH, sendq>$TB_SENDQ_THRESH) — возможны ложные баны мостов."
  else
    info "netstat-эвристики выключены: банится только реальный торрент-трафик."
  fi

  if [[ ! -f "$logpath" ]]; then
    warn "Файла $logpath пока нет. Он появится, когда нода начнёт писать access.log."
    warn "Проверь, что в конфиге ноды в панели включён лог доступа (loglevel не 'none')."
  fi
}

# Применяет настройки слоя B: юнит + перезапуск сервиса.
tb_apply() {
  is_torrent_blocker_installed || { warn "torrent-blocker не установлен."; return 1; }

  # Слой B работает по access.log, поэтому ротация обязательна: иначе лог,
  # который мы только что задействовали, со временем забьёт диск.
  install_log_rotation || warn "Ротация логов не настроена — следи за размером access.log."

  tb_write_unit
  run_shell "Перечитываю systemd и перезапускаю torrent-blocker" \
    "systemctl daemon-reload; systemctl enable torrent-blocker >/dev/null 2>&1 || true; systemctl restart torrent-blocker" || return 1

  sleep 2
  if systemctl is-active --quiet torrent-blocker 2>/dev/null; then
    ok "Сервис torrent-blocker активен с новыми настройками."
  else
    warn "Сервис не поднялся. Смотри: journalctl -u torrent-blocker -n 30"
    return 1
  fi
}

# ── Снятие банов слоя B ─────────────────────────────────────────────────────
#
# ВАЖНО: одного `torrent-blocker unban` недостаточно. Состояние блокера
# (/var/lib/torrent-blocker/blocked.json) и правила iptables — это ДВЕ разные
# вещи. Вендорский инсталлятор при переустановке удаляет blocked.json, а
# цепочка TORRENT_BAN в таблице raw остаётся как была. Результат: в статусе
# «banned IPs: 0», а трафик IP по-прежнему дропается, и счётчик пакетов в
# TORRENT_BAN растёт. Такие правила надо снимать напрямую.

# Печатает IP, которые ПРЯМО СЕЙЧАС дропаются цепочками слоя B.
# 0.0.0.0 отбрасываем: он приходит из записи 0.0.0.0/0 (destination any),
# а не является забаненным адресом.
# Всегда возвращает 0: цепочек может не быть вовсе (тогда вывод пустой), а
# скрипт работает под `set -Eeuo pipefail` — иначе отсутствие цепочки роняло бы
# вызывающего.
tb_active_ban_rules() {
  { iptables  -t raw -S TORRENT_BAN   2>/dev/null || true
    iptables         -S TORRENT_PEERS 2>/dev/null || true
    ip6tables -t raw -S TORRENT_BAN   2>/dev/null || true
  } | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|\b([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b' \
    | grep -vxE '0\.0\.0\.0|127\.0\.0\.1|::1' \
    | sort -u || true
}

# Чистит цепочки и ipset слоя B от осиротевших правил.
tb_purge_ban_rules() {
  local before left s

  before="$(tb_active_ban_rules | paste -sd' ' - || true)"

  iptables  -t raw -F TORRENT_BAN   2>/dev/null || true
  iptables         -F TORRENT_PEERS 2>/dev/null || true
  ip6tables -t raw -F TORRENT_BAN   2>/dev/null || true
  ip6tables        -F TORRENT_PEERS 2>/dev/null || true

  for s in auto_peers_v4 auto_peers_v6 auto_trackers_v4 auto_trackers_v6; do
    ipset flush "$s" 2>/dev/null || true
  done

  if [[ -n "$before" ]]; then
    ok "Из цепочек слоя B убраны IP: $before"
  else
    info "Осиротевших DROP-правил в цепочках слоя B не было."
  fi

  left="$(tb_active_ban_rules | paste -sd' ' - || true)"
  if [[ -n "$left" ]]; then
    warn "Всё ещё дропаются: $left"
    warn "Проверь вручную: iptables -t raw -S TORRENT_BAN; iptables -S TORRENT_PEERS"
    return 1
  fi

  return 0
}

# Снимает бан с одного IP: и в состоянии блокера, и в правилах iptables.
tb_unban_ip() {
  local ip="$1" removed=0

  "$TORRENT_BLOCKER_BIN" unban "$ip" >/dev/null 2>&1 || true

  # Правила могли остаться, если блокер про этот IP уже забыл (истёк таймер
  # или было удалено blocked.json) — снимаем их напрямую, в обе стороны.
  while iptables -t raw -C TORRENT_BAN -s "$ip" -j DROP 2>/dev/null; do
    iptables -t raw -D TORRENT_BAN -s "$ip" -j DROP && removed=$((removed + 1))
  done
  while iptables -t raw -C TORRENT_BAN -d "$ip" -j DROP 2>/dev/null; do
    iptables -t raw -D TORRENT_BAN -d "$ip" -j DROP && removed=$((removed + 1))
  done
  while iptables -C TORRENT_PEERS -d "$ip" -j DROP 2>/dev/null; do
    iptables -D TORRENT_PEERS -d "$ip" -j DROP && removed=$((removed + 1))
  done

  ipset del auto_peers_v4    "$ip" 2>/dev/null || true
  ipset del auto_trackers_v4 "$ip" 2>/dev/null || true

  if [[ "$removed" -gt 0 ]]; then
    ok "IP $ip разбанен (снято правил iptables: $removed)."
  else
    ok "IP $ip разбанен (правил iptables для него не было)."
  fi
}

# Снимает ВСЕ баны: состояние блокера + правила iptables/ipset.
tb_unban_all() {
  local ips ip n=0

  is_torrent_blocker_installed || { warn "torrent-blocker не установлен."; return 1; }

  # 1) То, что блокер ещё помнит сам — берём только из секции «Banned IPs»,
  #    иначе в выборку попадают адреса из дампа iptables (включая 0.0.0.0/0).
  ips="$("$TORRENT_BLOCKER_BIN" status 2>/dev/null \
    | sed -n '/Banned IPs/,/^[[:space:]]*$/p' \
    | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    | grep -vxE '0\.0\.0\.0|127\.0\.0\.1' | sort -u || true)"

  for ip in $ips; do
    "$TORRENT_BLOCKER_BIN" unban "$ip" >/dev/null 2>&1 && n=$((n + 1)) || true
  done

  if [[ "$n" -gt 0 ]]; then
    ok "Блокер снял банов из своего состояния: $n"
  else
    info "В состоянии блокера банов не было."
  fi

  # 2) Дочищаем правила — именно из-за этого шага «banned IPs: 0», а трафик
  #    всё равно дропался.
  tb_purge_ban_rules
}

torrent_blocker_whitelist_menu() {
  section "Слой B — белый список (мосты, релеи, свои сервисы)"

  tg_load_config

  local choice input ip
  while true; do
    echo
    info "Свои IP в белом списке: ${TB_BYPASS:-<нет>}"
    info "Итоговый --bypass (плюс localhost, IP панели и твоя SSH-сессия):"
    echo "${C_DIM}    $(tb_build_bypass)${C_RESET}"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Добавить IP"
    echo "  ${C_GREEN}2${C_RESET}) Удалить IP"
    echo "  ${C_GREEN}3${C_RESET}) Очистить свой список"
    echo "  ${C_CYAN}4${C_RESET}) Сохранить и применить"
    echo "  ${C_YELLOW}0${C_RESET}) Назад без применения"
    echo
    ask choice "  Выбор: "

    case "${choice:-}" in
      1)
        ask input "  IP (можно несколько через пробел): "
        for ip in ${input:-}; do
          if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
            TB_BYPASS="$(printf '%s %s\n' "$TB_BYPASS" "$ip" | tr ' ' '\n' | awk 'NF' | sort -u | paste -sd' ' -)"
          else
            warn "Пропускаю некорректный IP: $ip"
          fi
        done
        ;;
      2)
        ask input "  IP для удаления: "
        input="$(echo "${input:-}" | tr -d '[:space:]')"
        TB_BYPASS="$(printf '%s\n' $TB_BYPASS | awk 'NF' | grep -vxF "$input" | paste -sd' ' - || true)"
        ;;
      3) TB_BYPASS="" ;;
      4)
        tg_save_config
        ok "Белый список сохранён."
        tb_apply || true
        return 0
        ;;
      0|"") return 0 ;;
      *) warn "Некорректный выбор." ;;
    esac
  done
}

# Записывает на диск guard-скрипт (слой A). Внешний heredoc в кавычках ('GUARD'),
# поэтому весь текст попадает на диск как есть, без подстановок.
tg_write_guard_script() {
  mkdir -p "$(dirname "$TG_SCRIPT")" "$TG_DIR"

  cat > "$TG_SCRIPT" <<'GUARD'
#!/bin/bash
# =============================================================================
#  ds-guard.sh  —  DoubleServers VPS Guard (anti-torrent + packetsdk block)
#
#  Universal, self-healing installer for Ubuntu (all) / Debian 11/12/13.
#  What it installs (each auto-skipped if prerequisites are missing):
#    L1 nDPI     : inline DROP of BitTorrent (TCP peer-wire + UDP) via xt_ndpi
#    L2 Suricata : NFQUEUE IPS on UDP egress — DHT / uTP / tracker (ds-p2p rules)
#    L3 Domains  : SNI/HTTP-Host/DNS string-block of packetsdk (proxy-SDK abuse)
#                  + any extra domains via DS_DOMAINS
#
#  Non-interactive. Idempotent. Reboot- and firewall-reload-safe. Self-heals
#  the nDPI kernel module across kernel upgrades (DKMS + ExecStartPre).
#
#  Config via environment (all optional):
#    DS_TORRENT=1     enable L1 nDPI + L2 Suricata-UDP           (default 1)
#    DS_SURICATA=1    enable L2 Suricata separately from L1      (default 1)
#    DS_PACKETSDK=1   block packetsdk domain (built-in)          (default 1)
#    DS_DOMAINS=""    extra domains to block (space/comma list)  (default none)
#    DS_WAN=auto      egress interface                           (default auto)
#
#  Usage:  ds-guard.sh [--uninstall] [--status] [--dry-run]
#  Exit:   0 ok / partial-ok, 1 fatal (unsupported OS / no WAN)
# =============================================================================
set -u
export DEBIAN_FRONTEND=noninteractive
VERSION="1.6"
LOG=/var/log/ds-guard-install.log
NDPI_REPO="https://github.com/vel21ripn/nDPI.git"
NDPI_BRANCH="flow_info-4"
STATE_DIR=/etc/ds-guard
SBIN=/usr/local/sbin

# [eclipse] Настройки из файла, чтобы выбор в меню Eclipse Node Manager жил
# после перезагрузки и переустановки. Переменные окружения имеют приоритет.
[ -r "$STATE_DIR/config" ] && . "$STATE_DIR/config"

DS_TORRENT="${DS_TORRENT:-1}"
DS_SURICATA="${DS_SURICATA:-1}"   # [eclipse] L2 отключается отдельно от L1
DS_PACKETSDK="${DS_PACKETSDK:-1}"
DS_DOMAINS="${DS_DOMAINS:-}"
DS_WAN="${DS_WAN:-auto}"

c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log(){ printf '%s %b\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG" ; }
ok(){  log "${c_g}[ OK ]${c_0} $*"; }
warn(){ log "${c_y}[WARN]${c_0} $*"; }
err(){ log "${c_r}[FAIL]${c_0} $*"; }
die(){ err "$*"; log "aborting."; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
retry(){ local n=$1; shift; local i=1; until "$@"; do [ "$i" -ge "$n" ] && return 1; warn "retry $i/$n"; sleep $((i*3)); i=$((i+1)); done; }
APT_NET_OPTS="-o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25"
apt_install(){ retry 3 apt-get $APT_NET_OPTS -o DPkg::Lock::Timeout=300 -y -q install "$@" >>"$LOG" 2>&1; }
ensure_repos(){
  # nDPI/Suricata build deps (dkms, libpcap-dev, libxtables-dev, suricata, flex, bison...)
  # live in the 'universe' component. Minimal/cloud images sometimes ship without it,
  # which makes those packages "have no installation candidate". Enable it before deps.
  if grep -rhqs -E 'universe' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    return 0
  fi
  log "universe repo not enabled — adding it (needed for build deps + suricata)"
  local did=0 f
  # deb822 format (Ubuntu 24.04 /etc/apt/sources.list.d/ubuntu.sources)
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if grep -q '^Components:' "$f" && ! grep -q '^Components:.*universe' "$f"; then
      sed -i -E '/^Components:/ s/$/ universe/' "$f"; did=1
    fi
  done
  # legacy one-line format (deb ... noble main ...)
  if [ -f /etc/apt/sources.list ] && grep -qE '^[[:space:]]*deb .* main' /etc/apt/sources.list && ! grep -qE '^[[:space:]]*deb .* universe' /etc/apt/sources.list; then
    sed -i -E '/^[[:space:]]*deb .* main/ { /universe/! s/[[:space:]]*$/ universe/ }' /etc/apt/sources.list; did=1
  fi
  # last resort
  if [ "$did" = 0 ] && have add-apt-repository; then
    add-apt-repository -y universe >>"$LOG" 2>&1 && did=1
  fi
  [ "$did" = 1 ] && ok "universe enabled" || warn "could not enable universe automatically"
}

# ============================ PREFLIGHT =====================================
preflight(){
  [ "$(id -u)" = 0 ] || die "must run as root"
  mkdir -p "$STATE_DIR" "$SBIN"
  : > "$LOG" 2>/dev/null || LOG=/tmp/ds-guard-install.log
  log "=== ds-guard v$VERSION  $(date -u) ==="
  [ -r /etc/os-release ] || die "no /etc/os-release"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ok "OS: ${ID} ${VERSION_ID:-?}";;
    *) die "unsupported OS '${ID:-?}' (Ubuntu/Debian only)";;
  esac
  KREL="$(uname -r)"
  VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  case "$VIRT" in
    openvz|lxc|lxc-libvirt|docker|podman|wsl) MODULES_OK=0; warn "virt=$VIRT — container: kernel modules not loadable (nDPI/NFQUEUE limited)";;
    *) MODULES_OK=1; ok "virt=$VIRT — own kernel";;
  esac
  if [ "$DS_WAN" = auto ]; then WAN="$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"; else WAN="$DS_WAN"; fi
  { [ -n "${WAN:-}" ] && ip link show "$WAN" >/dev/null 2>&1; } || die "cannot determine WAN interface (set DS_WAN=)"
  ok "WAN interface: $WAN"
  have iptables || apt_install iptables
  IPT="iptables -w"; $IPT -S >/dev/null 2>&1 || die "iptables not functional"
  [ -d "/lib/modules/$KREL/build" ] && HEADERS_OK=1 || HEADERS_OK=0
}

base_deps(){
  log "--- apt update + base deps ---"
  ensure_repos
  if ! retry 3 apt-get $APT_NET_OPTS -o DPkg::Lock::Timeout=300 -y -q update >>"$LOG" 2>&1; then
    warn "apt update failed — falling back to archive.ubuntu.com"
    sed -i -E 's#https?://mirror\.hetzner\.com/ubuntu/packages#http://archive.ubuntu.com/ubuntu#g; s#https?://mirror\.hetzner\.com/ubuntu/security#http://security.ubuntu.com/ubuntu#g; s#https?://mirror\.hetzner\.com/ubuntu#http://archive.ubuntu.com/ubuntu#g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    retry 3 apt-get $APT_NET_OPTS -o DPkg::Lock::Timeout=300 -y -q update >>"$LOG" 2>&1 || warn "apt update issues (after fallback)"
  fi
  apt_install ca-certificates curl iptables >>"$LOG" 2>&1 || warn "some base deps failed"
  STRING_OK=0; $IPT -m string -h >/dev/null 2>&1 && STRING_OK=1
  NFQ_OK=0; modprobe nfnetlink_queue 2>/dev/null; $IPT -m conntrack -h >/dev/null 2>&1 && NFQ_OK=1
  ok "caps: string=$STRING_OK nfqueue=$NFQ_OK headers=$HEADERS_OK modules=$MODULES_OK"
}

# ============================ L1: nDPI ======================================
build_ndpi(){
  [ "$MODULES_OK" = 1 ] || { warn "L1 nDPI skipped (container)"; return 1; }
  # Re-run aware: was OUR nDPI already working before this run? If a rebuild
  # then fails, we fall back to it so a re-run never breaks a healthy server.
  local had_ndpi=0
  if modprobe xt_ndpi 2>/dev/null && $IPT -m ndpi --help >/dev/null 2>&1; then had_ndpi=1; fi
  [ "$had_ndpi" = 1 ] && log "--- L1: nDPI present — reinstalling (fresh rebuild) ---" || log "--- L1: installing nDPI (xt_ndpi) ---"
  # Kernel toolchain: Clang-built kernels (XanMod / custom) need the LLVM
  # toolchain for the out-of-tree module; a stock GCC kernel uses the default.
  local KMAKE=""
  if grep -qs 'CONFIG_CC_IS_CLANG=y' "/boot/config-$KREL" 2>/dev/null || grep -qi clang /proc/version 2>/dev/null; then
    log "custom Clang-built kernel detected (e.g. XanMod) — building module with LLVM=1"
    apt_install clang lld llvm || warn "clang/lld/llvm install failed"
    KMAKE="LLVM=1"
  fi
  apt_install "linux-headers-$KREL" || true
  if [ ! -d "/lib/modules/$KREL/build" ]; then
    _da="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    for _hp in linux-headers-generic "linux-headers-$_da" "linux-headers-cloud-$_da"; do apt_install "$_hp" && break; done
  fi
  [ -d "/lib/modules/$KREL/build" ] || { warn "no kernel headers for $KREL — L1 skipped"; return 1; }
  apt_install build-essential git autoconf automake libtool pkg-config libpcap-dev libgcrypt20-dev flex bison libxtables-dev dkms || warn "some nDPI deps failed to install"
  _miss=""; for _b in gcc make dkms pkg-config git; do have "$_b" || _miss="$_miss $_b"; done
  [ -n "$_miss" ] && { warn "nDPI build tools missing:$_miss — L1 skipped (enable universe/base repos)"; return 1; }
  cd /opt || return 1; rm -rf ndpi-build
  retry 2 git clone --depth 1 -b "$NDPI_BRANCH" "$NDPI_REPO" ndpi-build >>"$LOG" 2>&1 || { warn "git clone failed"; return 1; }
  ( cd /opt/ndpi-build && ./autogen.sh && ./configure && make -j"$(nproc)" ) >>"$LOG" 2>&1 || { warn "libnDPI build failed"; return 1; }
  ( cd /opt/ndpi-build/ndpi-netfilter && make -j"$(nproc)" $KMAKE ) >>"$LOG" 2>&1
  local KO SO; KO=$(find /opt/ndpi-build -name xt_ndpi.ko|head -1); SO=$(find /opt/ndpi-build -name libxt_ndpi.so|head -1)
  if [ -z "$KO" ] || [ -z "$SO" ]; then
    if [ "$had_ndpi" = 1 ]; then warn "nDPI rebuild did not complete — keeping the existing working module"; ndpi_conf; return 0; fi
    warn "L1 nDPI skipped (module could not be built on this kernel)"; return 1
  fi

  rm -rf /usr/src/ndpi-1.0; cp -a /opt/ndpi-build /usr/src/ndpi-1.0
  cat > /usr/src/ndpi-1.0/dkms.conf <<DK
PACKAGE_NAME="ndpi"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="xt_ndpi"
BUILT_MODULE_LOCATION[0]="ndpi-netfilter/src"
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make -C ndpi-netfilter/src KERNEL_DIR=/lib/modules/\${kernelver}/build modules $KMAKE"
CLEAN="make -C ndpi-netfilter/src KERNEL_DIR=/lib/modules/\${kernelver}/build clean"
AUTOINSTALL="yes"
DK
  dkms add -m ndpi -v 1.0 >>"$LOG" 2>&1; dkms build -m ndpi -v 1.0 >>"$LOG" 2>&1; dkms install -m ndpi -v 1.0 --force >>"$LOG" 2>&1
  modinfo xt_ndpi >/dev/null 2>&1 || { mkdir -p "/lib/modules/$KREL/updates/dkms"; cp "$KO" "/lib/modules/$KREL/updates/dkms/"; depmod -a; }
  local XTDIR; XTDIR="$(pkg-config --variable=xtlibdir xtables 2>/dev/null || echo /usr/lib/$(uname -m)-linux-gnu/xtables)"
  cp "$SO" "$XTDIR/libxt_ndpi.so" 2>/dev/null
  ndpi_conf
  # Reinstall refreshes the on-disk module (DKMS) + userspace lib; the running
  # module stays loaded (no live churn) and the OUTPUT rule is left to the
  # enforcer (install_enforcer / 5-min timer), so a re-run never drops it.
  modprobe xt_ndpi 2>/dev/null && $IPT -m ndpi --help >/dev/null 2>&1 && { ok "L1 nDPI (re)installed + loaded (bt_hash=32)"; return 0; }
  warn "xt_ndpi built but not loadable — L1 degraded"; return 1
}
ndpi_conf(){ echo 'options xt_ndpi bt_hash_size=32 bt_hash_timeout=1200' > /etc/modprobe.d/xt_ndpi.conf; echo 'xt_ndpi' > /etc/modules-load.d/xt_ndpi.conf; }

# ============================ L2: Suricata (UDP only) =======================
setup_suricata(){
  [ "$NFQ_OK" = 1 ] || { warn "L2 Suricata skipped (no NFQUEUE)"; return 1; }
  log "--- L2: Suricata (NFQUEUE, UDP) ---"
  have suricata || apt_install suricata || { warn "suricata install failed — L2 skipped"; return 1; }
  mkdir -p /etc/suricata/rules; write_ds_p2p_rules
  sed -i 's|^default-rule-path:.*|default-rule-path: /etc/suricata/rules|' /etc/suricata/suricata.yaml 2>/dev/null
  sed -i 's|^\([[:space:]]*\)- suricata.rules|\1- ds-p2p.rules|' /etc/suricata/suricata.yaml 2>/dev/null
  grep -q 'ds-p2p.rules' /etc/suricata/suricata.yaml 2>/dev/null || sed -i 's|^rule-files:.*|rule-files:\n  - ds-p2p.rules|' /etc/suricata/suricata.yaml 2>/dev/null
  mkdir -p /etc/systemd/system/suricata.service.d
  cat > /etc/systemd/system/suricata.service.d/nfqueue.conf <<'OVR'
[Service]
ExecStart=
ExecStart=/usr/bin/suricata -D -q 0 -q 1 -c /etc/suricata/suricata.yaml --pidfile /run/suricata.pid
OVR
  systemctl daemon-reload; systemctl reset-failed suricata 2>/dev/null
  suricata -T -c /etc/suricata/suricata.yaml >>"$LOG" 2>&1 || warn "suricata -T reported issues"
  systemctl enable suricata >>"$LOG" 2>&1; retry 2 systemctl restart suricata; sleep 2
  [ "$(systemctl is-active suricata)" = active ] && { ok "L2 Suricata active (NFQUEUE UDP)"; return 0; }
  warn "suricata not active — L2 degraded"; return 1
}
write_ds_p2p_rules(){
cat > /etc/suricata/rules/ds-p2p.rules <<'RULES'
# DoubleServers focused P2P / torrent detection (fed UDP-only via NFQUEUE).
drop tcp any any -> any any (msg:"DS P2P BitTorrent handshake"; flow:established; content:"|13|BitTorrent protocol"; depth:20; fast_pattern; classtype:policy-violation; sid:9000001; rev:1;)
drop udp any any -> any any (msg:"DS P2P BitTorrent DHT query (id)"; content:"d1:ad2:id20:"; fast_pattern; classtype:policy-violation; sid:9000002; rev:1;)
drop udp any any -> any any (msg:"DS P2P DHT get_peers"; content:"9:get_peers"; fast_pattern; classtype:policy-violation; sid:9000003; rev:1;)
drop udp any any -> any any (msg:"DS P2P DHT announce_peer"; content:"13:announce_peer"; fast_pattern; classtype:policy-violation; sid:9000004; rev:1;)
drop udp any any -> any any (msg:"DS P2P DHT find_node"; content:"9:find_node"; fast_pattern; classtype:policy-violation; sid:9000005; rev:1;)
drop udp any any -> any any (msg:"DS P2P UDP tracker connect"; content:"|00 00 04 17 27 10 19 80|"; depth:8; offset:0; fast_pattern; classtype:policy-violation; sid:9000006; rev:1;)
drop http any any -> any any (msg:"DS P2P HTTP tracker announce"; flow:to_server; http.uri; content:"info_hash="; fast_pattern; content:"peer_id="; classtype:policy-violation; sid:9000007; rev:1;)
drop http any any -> any any (msg:"DS P2P HTTP tracker scrape"; flow:to_server; http.uri; content:"info_hash="; content:"/scrape"; classtype:policy-violation; sid:9000008; rev:1;)
drop http any any -> any any (msg:"DS P2P torrent client User-Agent"; flow:to_server; http.user_agent; pcre:"/(uTorrent|BitTorrent\/|Transmission\/|libtorrent|Azureus|qBittorrent|Deluge|rtorrent|BitComet)/i"; classtype:policy-violation; sid:9000009; rev:1;)
drop tcp any any -> any any (msg:"DS P2P BitTorrent LSD BT-SEARCH"; content:"BT-SEARCH "; depth:10; fast_pattern; classtype:policy-violation; sid:9000010; rev:1;)
drop udp any any -> any any (msg:"DS P2P BitTorrent LSD BT-SEARCH (udp)"; content:"BT-SEARCH "; depth:10; fast_pattern; classtype:policy-violation; sid:9000011; rev:1;)
drop udp any any -> any any (msg:"DS P2P BitTorrent uTP bencode"; content:"d1:rd2:id20:"; fast_pattern; classtype:policy-violation; sid:9000012; rev:1;)
alert tcp any any -> any any (msg:"DS P2P magnet/info_hash in stream"; content:"xt=urn:btih:"; fast_pattern; classtype:policy-violation; sid:9000013; rev:1;)
drop udp any any -> any any (msg:"DS P2P DHT ping (a id)"; content:"1:q4:ping"; fast_pattern; classtype:policy-violation; sid:9000014; rev:1;)
RULES
}

# ============================ L3: domain block (packetsdk) ==================
setup_domains(){
  local list="$STATE_DIR/domains.txt"; : > "$list"
  [ "$DS_PACKETSDK" = 1 ] && echo "packetsdk" >> "$list"
  [ -n "$DS_DOMAINS" ] && echo "$DS_DOMAINS" | tr ', ' '\n' | sed '/^$/d' >> "$list"
  sort -u "$list" -o "$list"
  [ -s "$list" ] || { rm -f "$list"; return 0; }
  [ "$STRING_OK" = 1 ] || { warn "L3 domain block skipped (no -m string)"; return 1; }
  ok "L3 domain block list: $(tr '\n' ' ' <"$list")"
  return 0
}

# ============================ enforcer + self-heal ==========================
install_enforcer(){
  cat > "$SBIN/ds-guard-ensure.sh" <<'ENS'
#!/usr/bin/env bash
set -u
modprobe -q xt_ndpi 2>/dev/null && exit 0
command -v dkms >/dev/null 2>&1 && dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1
modprobe -q xt_ndpi 2>/dev/null; exit 0
ENS
  cat > "$SBIN/ds-guard-apply.sh" <<APPLY
#!/usr/bin/env bash
# Re-assert egress protection at OUTPUT (top of chain, above UFW ACCEPT + NFQUEUE). Idempotent.
set -u
IPT="iptables -w"
NIC="\$(ip -4 route show default 2>/dev/null | awk '/default/{print \$5; exit}')"
[ -n "\$NIC" ] || exit 0
LIST=$STATE_DIR/domains.txt
del(){ while \$IPT -C OUTPUT \$1 2>/dev/null; do \$IPT -D OUTPUT \$1; done; }

# --- L3 domain block chain (packetsdk etc.) ---
if [ -s "\$LIST" ] && \$IPT -m string -h >/dev/null 2>&1; then
  \$IPT -N DS_DOMAINS 2>/dev/null || \$IPT -F DS_DOMAINS
  while IFS= read -r d; do [ -n "\$d" ] || continue
    \$IPT -A DS_DOMAINS -m string --string "\$d" --algo bm --icase -m limit --limit 5/min -j LOG --log-prefix "DS-DOMBLK " 2>/dev/null
    \$IPT -A DS_DOMAINS -m string --string "\$d" --algo bm --icase -j DROP
  done < "\$LIST"
fi

# --- L1/L2 torrent ---
if [ "${DS_TORRENT}" = 1 ]; then
  modprobe -q xt_ndpi 2>/dev/null || true
  R_NFQ="-o \$NIC -p udp -m conntrack --ctstate NEW -j NFQUEUE --queue-balance 0:1 --queue-bypass"
  R_NDPI="-o \$NIC -m ndpi --proto bittorrent -j DROP"
  # NFQUEUE: assert if Suricata is INSTALLED (not merely active). --queue-bypass keeps it
  # safe while Suricata is (re)starting; this removes the first-boot race that left it off.
  # [eclipse] плюс проверка DS_SURICATA: L2 можно выключить, оставив L1.
  del "\$R_NFQ"
  if [ "${DS_SURICATA}" = 1 ] && command -v suricata >/dev/null 2>&1; then \$IPT -I OUTPUT 1 \$R_NFQ; fi
  # nDPI: let the freshly-built match settle before asserting the rule (bounded retry).
  for _i in 1 2 3 4 5; do \$IPT -m ndpi --help >/dev/null 2>&1 && break; modprobe -q xt_ndpi 2>/dev/null; sleep 1; done
  if \$IPT -m ndpi --help >/dev/null 2>&1; then del "\$R_NDPI"; \$IPT -I OUTPUT 1 \$R_NDPI; fi
fi
# domain-block jump LAST -> lands at OUTPUT pos 1 (above NFQUEUE so UDP DNS is caught)
if \$IPT -L DS_DOMAINS -n >/dev/null 2>&1; then
  while \$IPT -C OUTPUT -o "\$NIC" -j DS_DOMAINS 2>/dev/null; do \$IPT -D OUTPUT -o "\$NIC" -j DS_DOMAINS; done
  \$IPT -I OUTPUT 1 -o "\$NIC" -j DS_DOMAINS
fi
exit 0
APPLY
  chmod +x "$SBIN/ds-guard-ensure.sh" "$SBIN/ds-guard-apply.sh"
  cat > /etc/systemd/system/ds-guard.service <<'SVC'
[Unit]
Description=DoubleServers VPS Guard - anti-torrent + packetsdk block
After=network-online.target suricata.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=600
ExecStartPre=-/usr/local/sbin/ds-guard-ensure.sh
ExecStart=/usr/local/sbin/ds-guard-apply.sh
ExecStop=/bin/bash -c 'iptables -w -F DS_DOMAINS 2>/dev/null; true'
[Install]
WantedBy=multi-user.target
SVC
  cat > /etc/systemd/system/ds-guard-apply.service <<'ASVC'
[Unit]
Description=DoubleServers VPS Guard - re-assert egress rules (idempotent)
After=network-online.target suricata.service
[Service]
Type=oneshot
ExecStartPre=-/usr/local/sbin/ds-guard-ensure.sh
ExecStart=/usr/local/sbin/ds-guard-apply.sh
ASVC
  cat > /etc/systemd/system/ds-guard.timer <<'TMR'
[Unit]
Description=DoubleServers VPS Guard - periodic rule re-assert (self-heal vs firewall reloads)
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=ds-guard-apply.service
[Install]
WantedBy=timers.target
TMR
  systemctl daemon-reload
  systemctl enable --now ds-guard.service >>"$LOG" 2>&1
  systemctl enable --now ds-guard.timer >>"$LOG" 2>&1
  ok "enforcer + self-heal (5-min timer) installed (reboot & firewall-reload safe)"
}

# ============================ status / verify / uninstall ===================
status(){
  local IPT="iptables -w"
  echo "== ds-guard status =="
  echo "WAN: $(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  echo "xt_ndpi: loaded=$(lsmod 2>/dev/null|grep -c '^xt_ndpi') bt_hash=$(cat /sys/module/xt_ndpi/parameters/bt_hash_size 2>/dev/null)"
  echo "suricata: $(systemctl is-active suricata 2>/dev/null)  ds-guard: $(systemctl is-active ds-guard 2>/dev/null)"
  echo "domains blocked: $(tr '\n' ' ' </etc/ds-guard/domains.txt 2>/dev/null)"
  echo "OUTPUT rules:"; $IPT -S OUTPUT 2>/dev/null | grep -iE 'ndpi|NFQUEUE|DS_DOMAINS' | sed 's/^/  /'
  $IPT -L DS_DOMAINS -n -v 2>/dev/null | grep -i drop | sed 's/^/  domblk: /'
}
verify(){
  local IPT="iptables -w" s=0 t=0
  log "--- verify ---"
  if [ "$DS_TORRENT" = 1 ]; then
    t=$((t+1)); $IPT -S OUTPUT|grep -q 'ndpi --proto bittorrent' && { s=$((s+1)); ok "nDPI rule present"; } || warn "nDPI rule ABSENT"
    if [ "$DS_SURICATA" = 1 ]; then
      t=$((t+1)); systemctl is-active --quiet suricata && { s=$((s+1)); ok "suricata active"; } || warn "suricata not active"
    fi
  fi
  if [ -s "$STATE_DIR/domains.txt" ]; then
    t=$((t+1)); $IPT -S OUTPUT|grep -q 'DS_DOMAINS' && { s=$((s+1)); ok "domain-block (packetsdk) active"; } || warn "domain-block absent"
  fi
  log "verify: $s/$t layers confirmed"
}
uninstall(){
  log "=== ds-guard uninstall ==="
  systemctl disable --now ds-guard.timer ds-guard-apply.service ds-guard.service suricata 2>/dev/null
  local IPT="iptables -w" NIC; NIC="$(ip -4 route show default|awk '/default/{print $5;exit}')"
  for r in "-m ndpi --proto bittorrent -j DROP" "-p udp -m conntrack --ctstate NEW -j NFQUEUE --queue-balance 0:1 --queue-bypass" "-j DS_DOMAINS"; do
    while $IPT -C OUTPUT -o "$NIC" $r 2>/dev/null; do $IPT -D OUTPUT -o "$NIC" $r; done
  done
  $IPT -F DS_DOMAINS 2>/dev/null; $IPT -X DS_DOMAINS 2>/dev/null
  rm -f "$SBIN"/ds-guard-*.sh /etc/systemd/system/ds-guard.service /etc/systemd/system/ds-guard-apply.service /etc/systemd/system/ds-guard.timer /etc/systemd/system/suricata.service.d/nfqueue.conf
  systemctl daemon-reload
  ok "uninstalled (packages left; 'dkms remove ndpi/1.0 --all' to purge module)"; exit 0
}

# ============================ main ==========================================
case "${1:-}" in
  --uninstall) preflight; uninstall;;
  --status)    status; exit 0;;
esac
preflight
base_deps
[ "${1:-}" = --dry-run ] && { status; exit 0; }
# [eclipse] L1 и L2 включаются раздельно (DS_SURICATA).
if [ "$DS_TORRENT" = 1 ]; then
  build_ndpi
  [ "$DS_SURICATA" = 1 ] && setup_suricata || warn "L2 Suricata disabled by config (DS_SURICATA=0)"
fi
setup_domains
install_enforcer
verify
echo
status
log "=== done. log: $LOG ==="
GUARD

  chmod 700 "$TG_SCRIPT"
}

# Слой A: nDPI + Suricata + блок доменов. Долгий шаг (сборка модуля ядра из
# исходников), поэтому вывод живой.
install_torrent_guard_layer() {
  section "Torrent Guard · слой A (nDPI + Suricata + домены)"

  tg_load_config
  tg_save_config
  tg_write_guard_script
  ok "Guard-скрипт записан: $TG_SCRIPT"

  info "Слои: nDPI=$( [[ "$TG_TORRENT" == 1 ]] && echo вкл || echo выкл ) · Suricata=$( [[ "$TG_SURICATA" == 1 ]] && echo вкл || echo выкл ) · packetsdk=$( [[ "$TG_PACKETSDK" == 1 ]] && echo вкл || echo выкл )"
  info "Сборка модуля ядра nDPI занимает несколько минут — это нормально."

  if run_shell_live "Устанавливаю слой A (nDPI/Suricata/домены)" "'$TG_SCRIPT'"; then
    ok "Слой A установлен. Правила переустанавливаются таймером ds-guard.timer каждые 5 мин."
  else
    warn "Слой A завершился с ошибкой. Лог: $TG_LOG"
    return 1
  fi
}

# Слой B: Go-блокер, который банит клиента по логам xray.
install_torrent_blocker() {
  section "Torrent Guard · слой B (torrent-blocker, бан клиентов)"

  if is_torrent_blocker_installed; then
    ok "torrent-blocker уже установлен: $TORRENT_BLOCKER_BIN"
    info "Переустанавливаю: останавливаю сервис, удаляю бинарник, ставлю заново."

    run_shell "Останавливаю и удаляю старую версию torrent-blocker" \
      "systemctl stop torrent-blocker >/dev/null 2>&1 || true; rm -f '$TORRENT_BLOCKER_BIN'"
  else
    info "torrent-blocker не найден на сервере. Устанавливаю с нуля."
  fi

  tg_load_config

  if run_shell_live "Скачиваю и устанавливаю torrent-blocker" \
    "curl -fsSL '$TORRENT_BLOCKER_INSTALL_URL' | bash"; then
    ok "Сборка torrent-blocker завершена."
  else
    warn "Установка torrent-blocker завершилась с ошибкой или была прервана. Смотри вывод выше."
    return 1
  fi

  # Вендорский юнит переписываем своим: у него неверный путь к логу (путь
  # внутри контейнера) и включённые эвристики по числу соединений, из-за
  # которых банились мосты. Подробности — в комментарии к TB_NETSTAT выше.
  tg_save_config
  tb_apply || return 1

  # Ложные баны из прошлых запусков снимаем, иначе мост останется отрезанным
  # до истечения таймера.
  tb_unban_all || true
}

install_torrent_guard_all() {
  local rc=0

  install_torrent_guard_layer || rc=1
  install_torrent_blocker || rc=1

  echo
  if [[ "$rc" -eq 0 ]]; then
    ok "Torrent Guard установлен полностью: трафик глушится (слой A), клиенты банятся (слой B)."
  else
    warn "Часть слоёв Torrent Guard не установилась. Подробности выше и в логах."
  fi

  return "$rc"
}

torrent_guard_status() {
  section "Torrent Guard — статус"

  tg_load_config

  echo
  echo "${C_BOLD}  Слой A · трафик (nDPI / Suricata / домены)${C_RESET}"
  if tg_guard_installed; then
    "$TG_SCRIPT" --status 2>/dev/null | sed 's/^/    /' || true
    echo
    info "Таймер self-heal: $(systemctl is-enabled ds-guard.timer 2>/dev/null || echo '<не установлен>') · $(systemctl is-active ds-guard.timer 2>/dev/null || echo inactive)"
  else
    warn "Слой A не установлен."
  fi

  echo
  echo "${C_BOLD}  Слой B · бан клиентов (torrent-blocker)${C_RESET}"
  if is_torrent_blocker_installed; then
    info "Сервис: $(systemctl is-active torrent-blocker 2>/dev/null || echo inactive)"

    # Фактически дропаемые IP показываем ОТДЕЛЬНО от статистики блокера:
    # «banned IPs: 0» относится к его состоянию, а правила iptables могут
    # остаться осиротевшими и продолжать дропать трафик.
    local active
    active="$(tb_active_ban_rules | paste -sd' ' - || true)"
    if [[ -n "$active" ]]; then
      warn "Реально дропаются цепочками слоя B: $active"
      info "Если это свои мосты — пункт «Баны» → «Снять ВСЕ баны», затем добавь их в белый список."
    else
      ok "Активных DROP-правил слоя B нет."
    fi

    "$TORRENT_BLOCKER_BIN" status 2>/dev/null | sed 's/^/    /' || warn "Не удалось получить статистику."
  else
    warn "Слой B не установлен."
  fi
}

torrent_guard_logs() {
  section "Torrent Guard — логи"

  echo
  echo "${C_DIM}  Установка слоя A (последние 30 строк $TG_LOG):${C_RESET}"
  tail -n 30 "$TG_LOG" 2>/dev/null | sed 's/^/    /' || info "Лога пока нет."

  echo
  echo "${C_DIM}  Сработавшие правила Suricata (ds-p2p, последние 20):${C_RESET}"
  grep -h 'DS P2P' /var/log/suricata/fast.log 2>/dev/null | tail -n 20 | sed 's/^/    /' \
    || info "Совпадений Suricata пока нет."

  echo
  echo "${C_DIM}  Баны torrent-blocker (последние 20):${C_RESET}"
  journalctl -u torrent-blocker -n 20 --no-pager 2>/dev/null | sed 's/^/    /' \
    || info "Сервис torrent-blocker не установлен."
}

torrent_guard_ban_menu() {
  section "Torrent Guard — ручной бан/разбан IP"

  if ! is_torrent_blocker_installed; then
    warn "Слой B (torrent-blocker) не установлен — бан-листом управляет он."
    return 1
  fi

  local active
  active="$(tb_active_ban_rules | paste -sd' ' - || true)"

  echo
  if [[ -n "$active" ]]; then
    warn "Реально дропаются прямо сейчас: $active"
  else
    ok "Активных DROP-правил слоя B нет."
  fi

  echo "${C_DIM}  Статистика блокера (её «banned IPs» — только его состояние):${C_RESET}"
  "$TORRENT_BLOCKER_BIN" status 2>/dev/null | sed -n '1,6p' | sed 's/^/    /' || true

  local act ip
  echo
  echo "  ${C_GREEN}1${C_RESET}) Забанить IP"
  echo "  ${C_GREEN}2${C_RESET}) Разбанить IP"
  echo "  ${C_CYAN}3${C_RESET}) Снять ВСЕ баны ${C_DIM}(после ложного срабатывания)${C_RESET}"
  echo "  ${C_YELLOW}0${C_RESET}) Назад"
  echo
  ask act "  Выбор: "

  case "${act:-}" in
    1) ask ip "  IP для бана: " ;;
    2) ask ip "  IP для разбана: " ;;
    3) tb_unban_all; return 0 ;;
    *) return 0 ;;
  esac

  ip="$(echo "${ip:-}" | tr -d '[:space:]')"
  if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ || -z "$ip" ]]; then
    warn "Некорректный IP."
    return 1
  fi

  case "$act" in
    1) "$TORRENT_BLOCKER_BIN" ban "$ip" && ok "IP $ip забанен." || warn "Не удалось забанить $ip." ;;
    2) tb_unban_ip "$ip" ;;
  esac
}

torrent_guard_settings() {
  section "Torrent Guard — настройки слоёв"

  tg_load_config

  local choice input
  while true; do
    echo
    info "nDPI (L1, DROP торрент-трафика):      $( [[ "$TG_TORRENT" == 1 ]] && echo включён || echo выключен )"
    info "Suricata (L2, IPS по UDP):            $( [[ "$TG_SURICATA" == 1 ]] && echo включена || echo выключена )"
    info "Блок домена packetsdk (L3):           $( [[ "$TG_PACKETSDK" == 1 ]] && echo включён || echo выключен )"
    info "Доп. домены для блокировки:           ${TG_DOMAINS:-<нет>}"
    info "Слой B: эвристики по числу соединений: $( [[ "$TB_NETSTAT" == 1 ]] && echo "ВКЛЮЧЕНЫ (риск бана мостов)" || echo "выключены (банится только торрент)" )"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Переключить nDPI (L1)"
    echo "  ${C_GREEN}2${C_RESET}) Переключить Suricata (L2) ${C_DIM}— на Hysteria2-нодах это заметная нагрузка на CPU${C_RESET}"
    echo "  ${C_GREEN}3${C_RESET}) Переключить блок packetsdk (L3)"
    echo "  ${C_GREEN}4${C_RESET}) Задать доп. домены"
    echo "  ${C_GREEN}5${C_RESET}) Переключить netstat-эвристики слоя B ${C_DIM}(не различают торрент и мост)${C_RESET}"
    echo "  ${C_CYAN}6${C_RESET}) Сохранить и применить"
    echo "  ${C_YELLOW}0${C_RESET}) Назад без применения"
    echo
    ask choice "  Выбор: "

    case "${choice:-}" in
      1) [[ "$TG_TORRENT"   == 1 ]] && TG_TORRENT=0   || TG_TORRENT=1 ;;
      2) [[ "$TG_SURICATA"  == 1 ]] && TG_SURICATA=0  || TG_SURICATA=1 ;;
      3) [[ "$TG_PACKETSDK" == 1 ]] && TG_PACKETSDK=0 || TG_PACKETSDK=1 ;;
      4)
        ask input "  Домены через пробел или запятую (пусто — очистить): "
        TG_DOMAINS="$(echo "${input:-}" | tr -s ', ' ' ' | sed 's/^ *//; s/ *$//')"
        ;;
      5)
        if [[ "$TB_NETSTAT" == 1 ]]; then
          TB_NETSTAT=0
        else
          TB_NETSTAT=1
          warn "Эвристики считают только количество соединений. Мост или вторая нода"
          warn "легко даёт 400+ соединений и будет забанен как 'multi_conn_large_sendq'."
          warn "Если через сервер ходят мосты — добавь их в белый список (пункт меню)."
        fi
        ;;
      6)
        tg_save_config
        ok "Настройки сохранены: $TG_CONFIG"
        if tg_guard_installed; then
          install_torrent_guard_layer || true
        else
          warn "Слой A ещё не установлен — примени пункт «Установить/обновить всё»."
        fi
        is_torrent_blocker_installed && { tb_apply || true; }
        return 0
        ;;
      0|"") return 0 ;;
      *) warn "Некорректный выбор." ;;
    esac
  done
}

torrent_guard_uninstall() {
  section "Torrent Guard — удаление"

  local ans
  ask ans "  Удалить оба слоя (правила, сервисы, таймеры)? [y/N]: "
  case "${ans,,}" in y|yes|д|да) ;; *) info "Отменено."; return 0 ;; esac

  if tg_guard_installed; then
    run_shell_live "Удаляю слой A" "'$TG_SCRIPT' --uninstall" || warn "Слой A удалился не полностью."
    rm -f "$TG_SCRIPT"
  fi

  if is_torrent_blocker_installed; then
    run_shell "Удаляю слой B (torrent-blocker)" \
      "systemctl disable --now torrent-blocker >/dev/null 2>&1 || true;
       '$TORRENT_BLOCKER_BIN' stop >/dev/null 2>&1 || true;
       rm -f '$TORRENT_BLOCKER_BIN' /etc/systemd/system/torrent-blocker.service;
       rm -rf /var/lib/torrent-blocker;
       systemctl daemon-reload" || warn "Слой B удалился не полностью."
  fi

  ok "Torrent Guard удалён. Пакеты (suricata, dkms, nDPI-модуль) оставлены."
  info "Полностью убрать модуль ядра: dkms remove ndpi/1.0 --all"
}

torrent_guard_menu() {
  need_root
  tg_load_config

  while true; do
    clear_screen
    section "Torrent Guard (анти-торрент)"
    echo
    echo "  ${C_DIM}Слой A — глушит торрент-трафик (nDPI + Suricata + блок домена packetsdk).${C_RESET}"
    echo "  ${C_DIM}Слой B — банит клиента, который торрентит (по логам xray и netstat).${C_RESET}"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Установить / обновить всё ${C_DIM}(оба слоя)${C_RESET}"
    echo "  ${C_CYAN}2${C_RESET}) Только слой A ${C_DIM}(nDPI / Suricata / домены)${C_RESET}"
    echo "  ${C_CYAN}3${C_RESET}) Только слой B ${C_DIM}(torrent-blocker, бан клиентов)${C_RESET}"
    echo "  ${C_CYAN}4${C_RESET}) Статус"
    echo "  ${C_CYAN}5${C_RESET}) Логи и сработки"
    echo "  ${C_CYAN}6${C_RESET}) Баны: посмотреть / забанить / разбанить / снять все"
    echo "  ${C_GREEN}7${C_RESET}) Белый список слоя B ${C_DIM}(мосты, релеи — чтобы их не банило)${C_RESET}"
    echo "  ${C_CYAN}8${C_RESET}) Настройки слоёв"
    echo "  ${C_RED}9${C_RESET}) Удалить всё"
    echo "  ${C_YELLOW}0${C_RESET}) Назад"
    echo

    local choice
    ask choice "  Выбор [1..9/0]: " || choice="0"

    case "${choice:-}" in
      [1-9]) clear_screen ;;
    esac

    case "${choice:-}" in
      1) install_torrent_guard_all || true; pause_menu ;;
      2) install_torrent_guard_layer || true; pause_menu ;;
      3) install_torrent_blocker || true; pause_menu ;;
      4) torrent_guard_status; pause_menu ;;
      5) torrent_guard_logs; pause_menu ;;
      6) torrent_guard_ban_menu || true; pause_menu ;;
      7) torrent_blocker_whitelist_menu || true; pause_menu ;;
      8) torrent_guard_settings || true; pause_menu ;;
      9) torrent_guard_uninstall || true; pause_menu ;;
      0|q|Q) return 0 ;;
      *) warn "Неверный выбор: ${choice:-empty}"; sleep 1 ;;
    esac
  done
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
    ask input "  NODE_PORT [${DEFAULT_NODE_PORT}]: "
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
    ask choice "  Выбор [1/2/3/4]: "

    case "${choice:-1}" in
      1)
        REMNANODE_DIR="/opt/remnanode"
        break
        ;;
      2)
        while true; do
          ask user_input "  Имя пользователя (папка в /home): "
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
          ask path_input "  Абсолютный путь установки: "
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
  ask name_input "  Имя ноды [remnanode]: "
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
    ask input "  Порт Hysteria2 (UDP) [${DEFAULT_HY2_PORT}]: "
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
    ask input "  Порт VLESS+TCP+TLS [${DEFAULT_TLS_VLESS_PORT}]: "
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
    "loglevel": "info",
    "access": "/var/log/remnanode/access.log",
    "error": "/var/log/remnanode/error.log"
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
    },
    {
      "tag": "TORRENT",
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
        "type": "field",
        "ruleTag": "TORRENT_BY_PROTOCOL",
        "outboundTag": "TORRENT"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-public-tracker"
        ],
        "ruleTag": "TORRENT_BY_DOMAIN",
        "outboundTag": "TORRENT"
      },
      {
        "port": "6881-6889,51413,21413,17417,37305",
        "type": "field",
        "ruleTag": "TORRENT_BY_PORT",
        "outboundTag": "TORRENT"
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

# Спрашивает параметры REALITY-инбаунда. Логика зависит от того, поднимали ли
# selfsteal (SELFSTEAL_ENABLED):
#   • selfsteal ВКЛ  — маскировка под свой Caddy на этом же сервере. Спрашиваем
#     порт (обычно 443), свой домен (serverName) и локальный target-порт Caddy
#     (по умолчанию 9443). target = 127.0.0.1:<порт Caddy>.
#   • selfsteal ВЫКЛ — маскировка под чужой реальный сайт (borrowed SNI).
#     Спрашиваем ТОЛЬКО внешний домен (напр. www.samsung.com). Порт всегда 443,
#     target = <этот домен>:443 (а не 127.0.0.1 — иначе REALITY некуда
#     проксировать «легитимный» трафик и маскировка ломается).
ask_reality_params() {
  local input=""

  section "Параметры REALITY"

  if [[ "$SELFSTEAL_ENABLED" -eq 1 ]]; then
    while true; do
      ask input "  Порт VLESS+REALITY (TCP) [${DEFAULT_REALITY_PORT}]: "
      input="${input:-$DEFAULT_REALITY_PORT}"
      if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
        REALITY_PORT="$((10#$input))"
        break
      fi
      warn "Некорректный порт. Нужно число от 1 до 65535."
    done

    while true; do
      ask input "  Домен selfsteal (serverName), например safeeclipse.ru: "
      input="$(echo "${input:-}" | tr -d '[:space:]')"
      if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        REALITY_SNI="$input"
        break
      fi
      warn "Некорректный домен. Пример: safeeclipse.ru"
    done

    while true; do
      ask input "  Локальный target-порт selfsteal (Caddy) [${DEFAULT_REALITY_TARGET_PORT}]: "
      input="${input:-$DEFAULT_REALITY_TARGET_PORT}"
      if [[ "$input" =~ ^[0-9]{1,5}$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
        REALITY_TARGET_PORT="$((10#$input))"
        break
      fi
      warn "Некорректный порт. Нужно число от 1 до 65535."
    done

    REALITY_TARGET="127.0.0.1:${REALITY_TARGET_PORT}"
    ok "REALITY (selfsteal): порт $REALITY_PORT, SNI $REALITY_SNI, target $REALITY_TARGET"
  else
    # Без selfsteal: порт фиксирован 443 (стандарт для маскировки под HTTPS).
    REALITY_PORT="$DEFAULT_REALITY_PORT"
    info "Selfsteal не используется — порт REALITY фиксирован: $REALITY_PORT (стандарт)."
    echo
    info "Укажи внешний домен для маскировки (SNI). Требования: настоящий сайт на"
    info "TLS 1.3 + HTTP/2, не CDN-заглушка, желательно без соседства с твоим IP."
    info "Примеры: www.samsung.com, www.microsoft.com, www.nvidia.com"

    while true; do
      ask input "  Внешний домен (SNI/target), например www.samsung.com: "
      input="$(echo "${input:-}" | tr -d '[:space:]')"
      # На всякий случай убираем протокол/путь, если пользователь вставил URL.
      input="${input#http://}"
      input="${input#https://}"
      input="${input%%/*}"
      if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        REALITY_SNI="$input"
        break
      fi
      warn "Некорректный домен. Пример: www.samsung.com"
    done

    REALITY_TARGET_PORT="443"
    REALITY_TARGET="${REALITY_SNI}:443"
    ok "REALITY (внешний SNI): порт $REALITY_PORT, SNI $REALITY_SNI, target $REALITY_TARGET"
  fi

  ask_vless_encryption
}

# Спрашивает, включать ли VLESS Encryption (mlkem768x25519plus, пост-квант).
# Это дополнительный слой шифрования поверх VLESS, независимый от REALITY.
# Реальная генерация ключей происходит позже (generate_vless_encryption),
# когда образ remnawave/node уже скачан.
ask_vless_encryption() {
  local ans
  echo
  info "VLESS Encryption — пост-квантовый слой шифрования (ML-KEM-768) поверх"
  info "VLESS, поверх REALITY. Скрывает содержимое даже при компрометации ключей"
  info "REALITY. Требует свежий Xray на клиенте и сервере (25.9+). Режим: $VLESS_ENC_MODE."
  echo
  ask ans "  Использовать шифрование (VLESS Encryption)? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да)
      REALITY_ENCRYPTION_ENABLED=1
      ok "Шифрование VLESS будет включено (mlkem768x25519plus.${VLESS_ENC_MODE})."
      ;;
    *)
      REALITY_ENCRYPTION_ENABLED=0
      REALITY_DECRYPTION="none"
      ok "Шифрование VLESS выключено (decryption: none)."
      ;;
  esac
}

# Генерирует пару decryption/encryption для VLESS Encryption через `xray vlessenc`
# внутри образа remnawave/node. Берёт X25519-пару (первую в выводе), заменяет
# режим на VLESS_ENC_MODE (random) и заполняет REALITY_DECRYPTION (для inbound)
# и REALITY_ENCRYPTION (строка для клиента). Возвращает 1, если не удалось —
# тогда вызывающий откатывается на decryption: none.
generate_vless_encryption() {
  local out dec enc

  # `xray vlessenc` печатает две пары (X25519 и ML-KEM-768), каждая строкой вида
  #   "decryption": "mlkem768x25519plus.native.600s...."
  #   "encryption": "mlkem768x25519plus.native.0rtt...."
  # Берём первую (X25519) — короче и достаточно (обмен ключами всё равно
  # пост-квантовый). Пробуем оба способа вызова xray в образе.
  out="$(docker run --rm --entrypoint xray remnawave/node:latest vlessenc 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    out="$(docker run --rm remnawave/node:latest xray vlessenc 2>/dev/null || true)"
  fi

  [[ -n "$out" ]] || return 1

  dec="$(printf '%s\n' "$out" | grep -oE '"decryption": *"[^"]+"' | head -n1 | sed -E 's/.*"decryption": *"([^"]+)".*/\1/')"
  enc="$(printf '%s\n' "$out" | grep -oE '"encryption": *"[^"]+"' | head -n1 | sed -E 's/.*"encryption": *"([^"]+)".*/\1/')"

  [[ -n "$dec" && -n "$enc" ]] || return 1

  # Заменяем режим (второе поле после mlkem768x25519plus) на выбранный —
  # native → random. Режим меняет только представление ключа на проводе,
  # само ключевое вещество не трогается; обе стороны должны совпадать.
  dec="$(printf '%s' "$dec" | sed -E "s/^(mlkem768x25519plus)\.[a-z0-9]+\./\1.${VLESS_ENC_MODE}./")"
  enc="$(printf '%s' "$enc" | sed -E "s/^(mlkem768x25519plus)\.[a-z0-9]+\./\1.${VLESS_ENC_MODE}./")"

  REALITY_DECRYPTION="$dec"
  REALITY_ENCRYPTION="$enc"
  return 0
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

  # VLESS Encryption (если включено пользователем) — генерируем decryption/
  # encryption сейчас, когда образ ноды уже скачан.
  if [[ "$REALITY_ENCRYPTION_ENABLED" -eq 1 ]]; then
    if generate_vless_encryption; then
      ok "VLESS Encryption сгенерирован (mlkem768x25519plus.${VLESS_ENC_MODE})."
    else
      REALITY_DECRYPTION="none"
      REALITY_ENCRYPTION=""
      warn "Не удалось сгенерировать VLESS Encryption через 'xray vlessenc' (возможно, образ ноды со старым Xray < 25.9). Ставлю decryption: none, продолжаю без шифрования."
    fi
  fi

  config_path="$REMNANODE_DIR/panel-inbounds.json"

  cat > "$config_path" <<EOF_REALITY
{
  "log": {
    "loglevel": "info",
    "access": "/var/log/remnanode/access.log",
    "error": "/var/log/remnanode/error.log"
  },
  "inbounds": [
    {
      "tag": "VLESS_REALITY_${REALITY_PORT}_${suffix}",
      "port": $REALITY_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "$REALITY_DECRYPTION"
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
          "target": "$REALITY_TARGET",
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
    },
    {
      "tag": "TORRENT",
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
        "type": "field",
        "ruleTag": "TORRENT_BY_PROTOCOL",
        "outboundTag": "TORRENT"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-public-tracker"
        ],
        "ruleTag": "TORRENT_BY_DOMAIN",
        "outboundTag": "TORRENT"
      },
      {
        "port": "6881-6889,51413,21413,17417,37305",
        "type": "field",
        "ruleTag": "TORRENT_BY_PORT",
        "outboundTag": "TORRENT"
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
  if [[ "$REALITY_ENCRYPTION_ENABLED" -eq 1 && -n "$REALITY_ENCRYPTION" ]]; then
    echo
    echo "  ${C_BOLD}VLESS Encryption включён (mlkem768x25519plus.${VLESS_ENC_MODE}):${C_RESET}"
    echo "  ${C_BOLD}decryption (сервер, уже в конфиге):${C_RESET} $REALITY_DECRYPTION"
    echo "  ${C_BOLD}encryption (клиент — впиши в настройки подключения/панель):${C_RESET} $REALITY_ENCRYPTION"
  fi
  echo
  info "Скопируй JSON выше (или файл $config_path) в конфиг инбаундов ноды в панели Remnawave."
  info "publicKey и shortId укажи в настройках подключения клиента."
  if [[ "$REALITY_ENCRYPTION_ENABLED" -eq 1 && -n "$REALITY_ENCRYPTION" ]]; then
    info "Строку encryption укажи в клиенте/панели — decryption и encryption должны быть из одной пары."
  fi
}

# Скачивает docker-образ с несколькими попытками, а при явном отказе Docker
# Hub (например, "403 Forbidden" от registry-1.docker.io — блокировка/лимит
# по IP) пробует публичные зеркала из DOCKER_HUB_MIRRORS и перетегирует
# образ обратно в исходное имя, чтобы docker compose не пытался качать его
# заново.
# Тянет образ и печатает приблизительную скорость.
#
# Приблизительную честно: docker не сообщает объём скачанного, а размер образа
# на диске — это уже РАСПАКОВАННЫЕ слои, обычно в 2-3 раза больше того, что
# реально прошло по сети. Как индикатор «быстро/медленно» этого достаточно,
# поэтому число помечено «≈».
docker_pull_timed() {
  local msg="$1" image="$2"
  local t0 dt size

  t0="$SECONDS"
  run_cmd "$msg" docker pull "$image" || return 1
  dt=$(( SECONDS - t0 ))
  (( dt > 0 )) || dt=1

  size="$(docker image inspect --format '{{.Size}}' "$image" 2>/dev/null || true)"
  if [[ "$size" =~ ^[0-9]+$ ]]; then
    echo "         ≈ $(format_speed "$(( size / dt ))" "$size" "$dt")"
  fi

  return 0
}

pull_docker_image_with_fallback() {
  local image="$1"
  local attempt mirror mirror_image

  for attempt in 1 2 3; do
    if docker_pull_timed "Скачиваю образ $image (попытка $attempt/3)" "$image"; then
      return 0
    fi
    sleep 5
  done

  warn "Не удалось скачать $image напрямую с Docker Hub (docker.io). Пробую зеркала registry..."

  for mirror in "${DOCKER_HUB_MIRRORS[@]}"; do
    mirror_image="${mirror}/${image}"

    if docker_pull_timed "Скачиваю образ через зеркало $mirror" "$mirror_image"; then
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

# Строка монтирования /etc/letsencrypt для TLS-установок (пусто = не нужно).
# Глобальная, потому что её использует write_node_compose, который вызывается
# из setup_remnanode в двух местах (обычная запись и аварийный откат).
NODE_CERT_VOLUME_LINE=""

# Упал ли последний запуск контейнера на setrlimit.
#
# Подстановка процесса, а не `tail | grep -q`: под `set -o pipefail` grep -q
# выходит по первому совпадению и закрывает канал, tail получает SIGPIPE (141),
# и статус ВСЕГО пайпа становится 141 — то есть «совпадения нет» ровно тогда,
# когда оно есть. Здесь пайпа нет, и статус берётся только от grep.
log_has_rlimit_error() {
  grep -q 'setting rlimit' < <(tail -n 80 "$LOG_FILE" 2>/dev/null)
}

# Человекочитаемый потолок демона docker — для строки в выводе установки.
docker_rlimit_report() {
  local pid nofile nproc

  pid="$(dockerd_pid || true)"
  if [[ -z "$pid" ]]; then
    echo "демон не найден, считаю по текущей оболочке"
    return 0
  fi

  nofile="$(proc_hard_limit "$pid" "Max open files" || echo '?')"
  nproc="$(proc_hard_limit "$pid" "Max processes" || echo '?')"
  echo "nofile=$nofile, nproc=$nproc"
}

# Пишет docker-compose.yml ноды. $1/$2 — лимиты nofile/nproc. Если аргументов
# нет, блок ulimits не пишется вовсе — это аварийный откат, когда ядро не даёт
# выставить даже расчётный потолок.
write_node_compose() {
  local nofile="${1:-}" nproc="${2:-}" ulimits_block=""

  if [[ -n "$nofile" && -n "$nproc" ]]; then
    ulimits_block="    ulimits:
      nofile:
        soft: $nofile
        hard: $nofile
      nproc:
        soft: $nproc
        hard: $nproc"
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
${NODE_CERT_VOLUME_LINE}
${XRAY_VOLUME_LINE}
${ulimits_block}
    env_file:
      - .env
EOF_COMPOSE
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

  # Ограничение канала спрашиваем здесь, вместе с остальными параметрами:
  # tc применяется мгновенно и не зависит от того, поднята ли уже нода.
  section "Ограничение канала (опционально)"
  bandwidth_prompt install || true

  echo
  echo "  Вставь SECRET_KEY из панели Remnawave."
  echo "  Ввод скрытый, это нормально."
  # ask_secret сам переводит строку после скрытого ввода.
  ask_secret SECRET_KEY "  SECRET_KEY: "

  [[ -n "${SECRET_KEY:-}" ]] || die "SECRET_KEY пустой."

  mkdir -p "$REMNANODE_DIR" "$REMNANODE_LOG_DIR"
  save_node_dir
  cd "$REMNANODE_DIR"

  # Один суффикс на ноду — все её теги инбаундов будут уникальны между нодами.
  TAG_SUFFIX="$(gen_tag_suffix)"

  run_download "Скачиваю geosite.dat" geosite.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

  run_download "Скачиваю geoip.dat" geoip.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

  run_download "Скачиваю geosite_2.dat (RU rules)" geosite_2.dat "$RU_GEOSITE_URL"

  run_download "Скачиваю geoip_2.dat (RU rules)" geoip_2.dat "$RU_GEOIP_URL"

  # Каталог логов создаём и наполняем ДО первого старта контейнера: compose
  # монтирует ./logs в /var/log/remnanode, и если каталога нет, docker создаст
  # его сам — но уже как пустой том, а xray в конфиге пишет туда с loglevel
  # info, поэтому файлы должны существовать с самого начала.
  mkdir -p "$REMNANODE_LOG_DIR"
  chmod 755 "$REMNANODE_LOG_DIR"
  touch "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"
  chmod 644 "$REMNANODE_LOG_DIR/access.log" "$REMNANODE_LOG_DIR/error.log"
  ok "Каталог логов ноды: $REMNANODE_LOG_DIR (access.log, error.log)"

  # Ротация сразу: конфиг ноды идёт с loglevel info и включённым access.log —
  # без ротации он на нагруженной ноде съест диск.
  if install_log_rotation; then
    ok "Суточная ротация логов ноды настроена (7 суток, copytruncate)."
  else
    warn "Ротация логов не настроена — следи за размером access.log."
  fi

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

  NODE_CERT_VOLUME_LINE="$cert_volume_line"

  # Лимиты берём не «целевые», а достижимые: runc не может поднять rlimit
  # контейнера выше жёсткого лимита демона docker, и при превышении контейнер
  # не стартует вообще (error setting rlimit type 7: operation not permitted).
  local nofile_limit nproc_limit
  nofile_limit="$(container_rlimit_ceiling nofile)"
  nproc_limit="$(container_rlimit_ceiling nproc)"
  info "Лимиты контейнера ноды: nofile=$nofile_limit, nproc=$nproc_limit (потолок демона docker: $(docker_rlimit_report))"

  write_node_compose "$nofile_limit" "$nproc_limit"

  if ! pull_docker_image_with_fallback "remnawave/node:latest"; then
    warn "Образ remnawave/node:latest не удалось скачать заранее. docker compose up всё равно попробует сам."
  fi

  local up_ok=0 up_attempt=0 up_max=3 rlimit_fallback_done=0
  while (( up_attempt < up_max )); do
    up_attempt=$((up_attempt + 1))

    if run_cmd "Запускаю Remnawave Node (попытка $up_attempt/$up_max)" docker_compose up -d; then
      up_ok=1
      break
    fi

    # Страховка на случай, если расчётный потолок всё-таки оказался выше
    # реального (нестандартный runc, вложенная виртуализация, seccomp-профиль):
    # переписываем compose без блока ulimits и пробуем ещё раз. Нода с
    # дефолтными лимитами docker рабочая — это лучше, чем не запустившаяся нода.
    if [[ "$rlimit_fallback_done" -eq 0 ]] && log_has_rlimit_error; then
      rlimit_fallback_done=1
      warn "Контейнер не стартует из-за rlimit (ядро не даёт выставить запрошенные лимиты)."
      warn "Убираю блок ulimits из docker-compose.yml и пробую снова — нода будет с дефолтными лимитами docker."
      write_node_compose
      # Откат не должен съедать попытку: иначе если rlimit всплыл на последней
      # из трёх, исправленный compose так и не был бы запущен.
      up_max=$((up_max + 1))
      continue
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
    ask choice "  Выбор [1/2/3/0]: "
    case "${choice:-}" in
      1) target_ver="$stable_ver"; break ;;
      2) target_ver="$actual_ver"; break ;;
      3)
        ask input "  Тег версии (с v, например v1.8.24): "
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

  if ! run_download "Скачиваю Xray $tag" "$tmpdir/xray.zip" "$url"; then
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

# Прописывает в rc-файлы функцию clear, которая чистит и буфер прокрутки.
#
# Штатный clear шлёт только \033[2J — видимая область очищается, а scrollback
# остаётся, и после выхода из меню вся консоль забита предыдущим выводом.
# \033[3J чистит именно его. Пишем блоком с маркерами и проверяем маркер перед
# записью, поэтому функция идемпотентна: повторный запуск не плодит дубли.
ECLIPSE_CLEAR_MARKER="# >>> eclipse clear fix >>>"

install_clear_fix() {
  local rc changed=0

  # ${HOME:-/root}: под `set -u` голое $HOME уронило бы скрипт там, где
  # переменная не выставлена (sudo -E, systemd-юнит, cron).
  for rc in "${HOME:-/root}/.bashrc" "${HOME:-/root}/.zshrc"; do
    # .zshrc создаём только если zsh реально есть или файл уже существует —
    # иначе оставляли бы мусор в домашнем каталоге на серверах без zsh.
    if [[ "$rc" == *.zshrc && ! -e "$rc" ]] && ! command -v zsh >/dev/null 2>&1; then
      continue
    fi

    if [[ -f "$rc" ]] && grep -qF "$ECLIPSE_CLEAR_MARKER" "$rc" 2>/dev/null; then
      continue
    fi

    cat >> "$rc" <<EOF_CLEARFIX

$ECLIPSE_CLEAR_MARKER
# Чистит экран вместе с буфером прокрутки (\\033[3J), а не только видимую часть.
clear() {
    printf '\\033[2J\\033[3J\\033[H'
}
# <<< eclipse clear fix <<<
EOF_CLEARFIX

    changed=1
    log_line "clear fix appended to $rc"
  done

  [[ "$changed" -eq 1 ]] && return 0
  return 1
}

# Создаёт короткую команду `eclipse` для запуска менеджера. Если системной
# копии скрипта ещё нет — сохраняет туда текущий файл, затем делает симлинк.
ensure_eclipse_command() {
  # Ставим заодно фикс clear — функция идемпотентна, повторные запуски ничего
  # не дописывают. В ТЕКУЩЕЙ оболочке он не подхватится (её rc уже прочитан):
  # нужен новый вход по SSH или `source ~/.bashrc`. Меню это не касается — оно
  # чистит экран через clear_screen напрямую.
  install_clear_fix >/dev/null 2>&1 || true

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

# ── Домен панели (общий для UFW и Eclipse Firewall) ──────────────────────────

# Заполняются panel_domain_prompt.
PANEL_DOMAIN=""
PANEL_IPV4=""
PANEL_IPV6=""

# Вырезает домен из того, что вставил пользователь: схему, креды, порт, путь.
# Позволяет вставить ссылку целиком, например
# https://panel.cloud134.ru/dashboard/management/nodes → panel.cloud134.ru
# Печатает домен или ничего, если это не похоже на FQDN.
panel_domain_normalize() {
  local s="${1:-}"

  s="$(echo "$s" | tr -d '[:space:]')"
  s="${s#*://}"     # схема
  s="${s#*@}"       # user:pass@
  s="${s%%/*}"      # путь
  s="${s%%\?*}"     # query
  s="${s%%:*}"      # порт
  s="${s,,}"

  [[ "$s" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || return 0
  echo "$s"
}

# Спрашивает домен панели Remnawave, резолвит A/AAAA и сохраняет в
# $ECLIPSE_PANEL_DOMAIN_FILE. Файл общий для UFW и Eclipse Firewall (пункт 10):
# домен указывается один раз, оба фаервола берут IP панели оттуда.
# Заполняет PANEL_DOMAIN / PANEL_IPV4 / PANEL_IPV6.
# Возвращает 1, если пользователь отменил ввод.
panel_domain_prompt() {
  local input v4 v6 ans saved

  PANEL_DOMAIN=""
  PANEL_IPV4=""
  PANEL_IPV6=""

  # 2>/dev/null ДО `<` — см. комментарий в bandwidth_current.
  saved="$(tr -d '[:space:]' 2>/dev/null < "$ECLIPSE_PANEL_DOMAIN_FILE" || true)"

  echo
  info "Укажи домен панели Remnawave (например, panel.example.com). Можно вставить"
  info "ссылку целиком — https://panel.example.com/dashboard/... — лишнее отрежется."
  echo

  while true; do
    if [[ -n "$saved" ]]; then
      ask input "  Домен панели [$saved]: "
      input="${input:-$saved}"
    else
      ask input "  Домен панели: "
    fi

    input="$(panel_domain_normalize "${input:-}")"
    [[ -n "$input" ]] && break
    warn "Некорректный домен. Пример: panel.example.com"
  done

  v4="$(na_resolve_domain_v4 "$input" | xargs || true)"
  v6="$(na_resolve_domain_v6 "$input" | xargs || true)"

  echo
  info "Домен панели: $input"
  info "IPv4 панели: ${v4:-<не найдено>}"
  info "IPv6 панели: ${v6:-<нет>}"

  if [[ -z "$v4$v6" ]]; then
    warn "DNS не вернул IP для $input. Ограничивать порт ноды этим доменом сейчас нельзя."
    ask ans "  Всё равно сохранить домен и продолжить? [y/N]: "
    case "${ans,,}" in y|yes|д|да) ;; *) warn "Отменено."; return 1 ;; esac
  fi

  mkdir -p "$ECLIPSE_FW_DIR"
  echo "$input" > "$ECLIPSE_PANEL_DOMAIN_FILE"
  ok "Домен панели сохранён: $input"

  PANEL_DOMAIN="$input"
  PANEL_IPV4="$v4"
  PANEL_IPV6="$v6"
  return 0
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

# Печатает NODE_PORT всех установленных на сервере нод Remnawave (по одному на
# строку, без дублей). Контейнер поднят с network_mode: host, поэтому нода
# слушает этот порт прямо на хосте — именно через него панель достукивается.
detect_node_ports() {
  local d port

  for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
    [[ -f "$d/.env" && -f "$d/docker-compose.yml" ]] || continue
    grep -q 'remnawave/node' "$d/docker-compose.yml" 2>/dev/null || continue

    port="$(grep -E '^NODE_PORT=' "$d/.env" 2>/dev/null | head -n1 | cut -d= -f2 | tr -d '[:space:]')"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || continue

    echo "$port"
  done | sort -un
}

# Открывает порты установленных нод всем (allow <port>/tcp). Печатает открытые.
firewall_allow_node_ports() {
  local port opened=()

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    opened+=("$port")
  done < <(detect_node_ports)

  [[ ${#opened[@]} -gt 0 ]] && info "Порты нод (NODE_PORT) открыты: ${opened[*]}"
  return 0
}

# Открывает порты нод ТОЛЬКО для IP панели: снимает общее «allow <port>/tcp»
# и вместо него добавляет точечные «allow from <ip> to any port <port>».
# Аргументы: список IPv4 и список IPv6 панели (через пробел).
# Возвращает 1, если IP панели неизвестны или нод на сервере нет — в этом случае
# правила не трогаются, чтобы панель не потеряла ноду.
ufw_restrict_node_ports_to_panel() {
  local v4="${1:-}" v6="${2:-}"
  local port ip restricted=()

  if [[ -z "${v4}${v6}" ]]; then
    warn "IP панели неизвестны — порты нод не ограничиваю."
    return 1
  fi

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue

    # Снимаем «открыто всем», если такое правило уже добавляли раньше.
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true

    for ip in $v4 $v6; do
      ufw allow from "$ip" to any port "$port" proto tcp >/dev/null 2>&1 || true
    done

    restricted+=("$port")
  done < <(detect_node_ports)

  if [[ ${#restricted[@]} -eq 0 ]]; then
    warn "Установленных нод не найдено — ограничивать нечего."
    return 1
  fi

  ok "Порты нод (${restricted[*]}) открыты только для IP панели: ${v4} ${v6}"
  info "Если у панели сменится IP — повтори этот пункт (UFW не ре-резолвит домен сам)."
  return 0
}

# Спрашивает домен панели и ограничивает порты нод её IP. Отдельным пунктом
# меню — чтобы можно было обновить IP панели, не переключая UFW.
ufw_setup_panel_access() {
  section "Порты нод — доступ только для панели"

  panel_domain_prompt || return 1
  ufw_restrict_node_ports_to_panel "$PANEL_IPV4" "$PANEL_IPV6"
}

# По умолчанию всегда открыты порты SSH, 80/tcp, 443/tcp и 443/udp
# (QUIC/HTTP3/Hysteria2 идут по UDP), плюс порты установленных нод. SSH первым —
# чтобы не потерять доступ при включении фаервола. Порт SSH берём из
# sshd_config и из текущей сессии ($SSH_CONNECTION), а не только 22: на многих
# серверах SSH перевешен, и «ufw allow 22» отрезал бы доступ вместе с фаерволом.
apply_firewall_defaults() {
  local p

  for p in $(na_detect_ssh_ports); do
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  done

  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 443/udp >/dev/null 2>&1 || true

  firewall_allow_node_ports
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

  info "По умолчанию открыты 22/tcp (SSH), 80/tcp, 443/tcp, 443/udp и порты установленных нод."
  apply_firewall_defaults

  local choice port ans
  while true; do
    clear_screen
    section "Настройка портов (UFW)"
    firewall_show
    echo
    echo "  ${C_GREEN}1${C_RESET}) Разрешить порт"
    echo "  ${C_GREEN}2${C_RESET}) Закрыть порт"
    echo "  ${C_GREEN}3${C_RESET}) Включить UFW"
    echo "  ${C_GREEN}4${C_RESET}) Выключить UFW"
    echo "  ${C_GREEN}5${C_RESET}) Обновить список открытых портов"
    echo "  ${C_CYAN}6${C_RESET}) Порты нод — только для панели ${C_DIM}(указать домен панели)${C_RESET}"
    echo "  ${C_YELLOW}0${C_RESET}) Назад"
    echo
    ask choice "  Выбор: "

    case "${choice:-}" in
      [1-6]) clear_screen ;;
    esac

    case "${choice:-}" in
      1)
        ask port "  Порт (например 2222 или 2222/udp): "
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
        ask port "  Порт для закрытия (например 2222 или 2222/udp): "
        port="$(echo "${port:-}" | tr -d '[:space:]')"
        if [[ "$port" =~ ^(22|80|443)(/tcp)?$ ]]; then
          warn "Порт $port относится к базовым (22/80/443) — закрывать не рекомендую (можно потерять доступ)."
          ask ans "  Всё равно закрыть? [y/N]: "
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

        # Порт ноды нужен только панели Remnawave, а не всему интернету —
        # поэтому при включении фаервола сразу спрашиваем её адрес и открываем
        # порты нод точечно (тот же домен, что использует Eclipse Firewall).
        echo
        info "Порт ноды нужен только панели Remnawave — остальным его можно закрыть."
        ask ans "  Ограничить порты нод IP панели? [Y/n]: "
        case "${ans,,}" in
          n|no|н|нет)
            info "Порты нод остаются открытыми для всех."
            ;;
          *)
            if panel_domain_prompt; then
              ufw_restrict_node_ports_to_panel "$PANEL_IPV4" "$PANEL_IPV6" \
                || warn "Порты нод оставлены открытыми для всех."
            else
              warn "Домен панели не указан — порты нод остаются открытыми для всех."
            fi
            ;;
        esac

        if ufw --force enable >/dev/null 2>&1; then
          ok "UFW включён (SSH, 80/tcp, 443/tcp, 443/udp, порты нод и добавленные порты открыты)."
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
      5) continue ;;
      6) ufw_setup_panel_access || true ;;
      0|"") break ;;
      *) warn "Некорректный выбор." ;;
    esac

    # Экран чистится в начале следующей итерации, поэтому без паузы результат
    # («Разрешён порт 2222») мелькнул бы и пропал.
    pause_menu
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

# ── Ограничение исходящего канала (shaping через tc) ────────────────────────
#
# Ограничиваем именно ИСХОДЯЩУЮ скорость WAN-интерфейса: на VPN-ноде это то,
# что уходит клиентам и в интернет, и именно за это считает трафик провайдер.
# Входящий шейпить с самого хоста смысла нет — пакеты уже прошли по каналу, и
# ingress-ограничение даёт только потери, от которых TCP становится хуже.
#
# Чем применяем:
#   1) sch_cake, если модуль есть в ядре — одна строка, честное разделение
#      между потоками и встроенное сглаживание. Лучший вариант для шейпинга,
#      в XanMod и штатных ядрах Ubuntu/Debian он есть.
#   2) Фоллбэк — HTB с fq на листе. fq на листе оставлен сознательно: BBR
#      полагается на пакетное сглаживание (pacing), а замена root-qdisc на
#      голый HTB его убирает.
#
# Значение хранится в файле, применяется systemd-юнитом при загрузке — иначе
# qdisc теряется после каждого reboot и при переподнятии интерфейса.

ECLIPSE_SHAPE_FILE="$ECLIPSE_FW_DIR/bandwidth_mbit"
ECLIPSE_SHAPE_SCRIPT="/usr/local/sbin/eclipse-bandwidth.sh"

# Текущее сохранённое ограничение в Мбит/с (пусто = ограничения нет).
#
# Проверка -r обязательна: в `tr ... < "$FILE" 2>/dev/null` перенаправления
# обрабатываются слева направо, поэтому падение `< $FILE` печатает
# "No such file or directory" ЕЩЁ ДО того, как stderr уйдёт в /dev/null.
bandwidth_current() {
  local v

  [[ -r "$ECLIPSE_SHAPE_FILE" ]] || return 0

  v="$(tr -cd '0-9' 2>/dev/null < "$ECLIPSE_SHAPE_FILE" || true)"
  [[ -n "$v" && "$v" != "0" ]] && echo "$v" || true
}

# Печатает первую строку root-qdisc интерфейса, если это шейпер — включая
# ЧУЖОЙ (tbf от провайдера, htb от другого скрипта). Нужно, чтобы статус не
# врал «ограничения нет», когда канал реально зажат не нами.
bandwidth_detected_qdisc() {
  local iface="${1:-}" line

  [[ -n "$iface" ]] || return 0
  command -v tc >/dev/null 2>&1 || return 0

  line="$(tc qdisc show dev "$iface" root 2>/dev/null | head -n1 || true)"
  [[ -n "$line" ]] || return 0

  case " $line " in
    *" cake "*|*" htb "*|*" tbf "*|*" hfsc "*|*" tbf,"*) printf '%s' "$line" ;;
  esac

  return 0
}

# Пишет на диск скрипт применения ограничения. Его же вызывает systemd при
# загрузке, поэтому вся логика выбора qdisc живёт там, а не в меню.
bandwidth_write_script() {
  mkdir -p "$(dirname "$ECLIPSE_SHAPE_SCRIPT")" "$ECLIPSE_FW_DIR"

  cat > "$ECLIPSE_SHAPE_SCRIPT" <<'SHAPE'
#!/usr/bin/env bash
# Применяет ограничение ИСХОДЯЩЕЙ скорости на WAN-интерфейсе.
# Значение (Мбит/с) читается из /etc/eclipse/bandwidth_mbit.
# Пусто, 0 или аргумент --clear = ограничения нет, qdisc сбрасывается.
set -u

LIMIT_FILE=/etc/eclipse/bandwidth_mbit

IFACE="$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"
if [ -z "${IFACE:-}" ]; then
  echo "WAN-интерфейс не определён — нечего ограничивать."
  exit 0
fi

if [ "${1:-}" = "--clear" ]; then
  MBIT=""
else
  MBIT="$(tr -cd '0-9' < "$LIMIT_FILE" 2>/dev/null || true)"
fi

# Снимаем наш qdisc в любом случае: и при сбросе, и перед переприменением
# (иначе повторный add вернёт "File exists").
tc qdisc del dev "$IFACE" root 2>/dev/null || true

if [ -z "$MBIT" ] || [ "$MBIT" = "0" ]; then
  echo "Ограничение снято: $IFACE вернулся к дефолтному qdisc ядра."
  exit 0
fi

# 1) CAKE — предпочтительный вариант.
modprobe sch_cake 2>/dev/null || true
if tc qdisc add dev "$IFACE" root cake bandwidth "${MBIT}mbit" 2>/dev/null; then
  echo "CAKE: $IFACE ограничен ${MBIT} Мбит/с"
  exit 0
fi

# 2) Фоллбэк HTB + fq на листе (fq нужен для pacing, на который опирается BBR).
if tc qdisc add dev "$IFACE" root handle 1: htb default 10 2>/dev/null \
  && tc class add dev "$IFACE" parent 1: classid 1:10 htb \
       rate "${MBIT}mbit" ceil "${MBIT}mbit" burst 1mbit 2>/dev/null; then
  tc qdisc add dev "$IFACE" parent 1:10 handle 10: fq 2>/dev/null || true
  echo "HTB+fq: $IFACE ограничен ${MBIT} Мбит/с"
  exit 0
fi

echo "Не удалось применить ограничение на $IFACE (проверь: tc qdisc show dev $IFACE)"
exit 1
SHAPE

  chmod 755 "$ECLIPSE_SHAPE_SCRIPT"

  cat > /etc/systemd/system/eclipse-bandwidth.service <<EOF_SHAPESVC
[Unit]
Description=Eclipse egress bandwidth limit (tc)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ECLIPSE_SHAPE_SCRIPT
ExecStop=-$ECLIPSE_SHAPE_SCRIPT --clear

[Install]
WantedBy=multi-user.target
EOF_SHAPESVC

  systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
}

# Применяет ограничение $1 Мбит/с (пусто/0 — снимает) и включает автозапуск.
bandwidth_apply() {
  local mbit="${1:-}"

  command -v tc >/dev/null 2>&1 || run_cmd "Устанавливаю iproute2 (tc)" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 || true

  mkdir -p "$ECLIPSE_FW_DIR"
  bandwidth_write_script

  if [[ -z "$mbit" || "$mbit" == "0" ]]; then
    : > "$ECLIPSE_SHAPE_FILE"
    "$ECLIPSE_SHAPE_SCRIPT" --clear | sed 's/^/  /' || true
    systemctl disable --now eclipse-bandwidth.service >> "$LOG_FILE" 2>&1 || true
    ok "Ограничение канала снято."
    return 0
  fi

  echo "$mbit" > "$ECLIPSE_SHAPE_FILE"

  if "$ECLIPSE_SHAPE_SCRIPT" | sed 's/^/  /'; then
    systemctl enable --now eclipse-bandwidth.service >> "$LOG_FILE" 2>&1 || true

    # Скрипт может отчитаться успехом, а qdisc в ядре не остаться: нет sch_cake
    # и sch_htb, LXC без CAP_NET_ADMIN, интерфейс переопределился. Проверяем
    # фактом, а не кодом возврата.
    local iface applied
    iface="$(detect_iface)"
    applied="$(bandwidth_detected_qdisc "$iface")"

    if [[ -n "$applied" ]]; then
      ok "Исходящая скорость ограничена: ${mbit} Мбит/с (применяется и после reboot)."
      info "Активный qdisc: $applied"
    else
      warn "Значение сохранено (${mbit} Мбит/с), но шейпера на ${iface:-интерфейсе} не видно."
      warn "Проверь вручную: tc qdisc show dev ${iface:-eth0}"
      return 1
    fi
  else
    warn "Не удалось применить ограничение. Значение сохранено, но qdisc не встал."
    return 1
  fi
}

bandwidth_status() {
  local iface cur foreign
  iface="$(detect_iface)"
  cur="$(bandwidth_current)"
  foreign="$(bandwidth_detected_qdisc "$iface")"

  echo
  if [[ -n "$cur" ]]; then
    ok "Ограничение исходящей скорости (наше): ${cur} Мбит/с (интерфейс ${iface:-неизвестен})"
  elif [[ -n "$foreign" ]]; then
    # Канал зажат, но не нами: типичный случай — tbf, который выставил
    # провайдер или прошлый скрипт. Если применить наше ограничение, этот
    # qdisc будет заменён (tc qdisc del root), поэтому предупреждаем прямо.
    warn "Своего ограничения нет, но на $iface УЖЕ висит шейпер (не наш):"
    echo "${C_DIM}    $foreign${C_RESET}"
    info "Если задать скорость здесь — этот qdisc будет заменён нашим."
  else
    info "Ограничения исходящей скорости нет."
  fi

  info "Автозапуск: $(systemctl is-enabled eclipse-bandwidth.service 2>/dev/null || echo '<не установлен>')"

  if [[ -n "$iface" ]] && command -v tc >/dev/null 2>&1; then
    echo
    echo "${C_DIM}  Активный qdisc на $iface:${C_RESET}"
    tc -s qdisc show dev "$iface" 2>/dev/null | sed 's/^/    /' || true
  fi
}

# Спрашивает скорость и применяет. $1=install — формулировка для установки
# (Enter = без ограничения); иначе меню (Enter = отмена, 0 = снять).
bandwidth_prompt() {
  local mode="${1:-menu}"
  local iface cur foreign input

  iface="$(detect_iface)"
  cur="$(bandwidth_current)"
  foreign="$(bandwidth_detected_qdisc "$iface")"

  echo
  info "Ограничение вешается на ИСХОДЯЩИЙ трафик WAN-интерфейса (${iface:-не определён})."
  info "Входящую скорость с самого сервера ограничить нельзя — трафик уже пришёл по каналу."

  # Тот же разбор, что и в bandwidth_status. При установке ноды это важнее
  # всего: канал часто уже зажат чужим tbf/htb (провайдер, прошлый скрипт),
  # и без этой проверки нода молча упиралась бы в потолок, которого никто не
  # ставил, а «Сейчас ограничения нет» вводило бы в заблуждение.
  if [[ -n "$cur" ]]; then
    info "Сейчас установлено: ${cur} Мбит/с"
  elif [[ -n "$foreign" ]]; then
    warn "Своего ограничения нет, но на ${iface} УЖЕ висит шейпер (не наш):"
    echo "${C_DIM}    $foreign${C_RESET}"
    info "Если задать скорость здесь — этот qdisc будет заменён нашим."
  else
    info "Сейчас ограничения нет."
  fi
  echo

  if [[ "$mode" == "install" ]]; then
    ask input "  Ограничить канал? Если да — введи скорость в Мбит/с (Enter — без ограничения): "
  else
    ask input "  Скорость в Мбит/с (Enter — отмена, 0 — снять ограничение): "
  fi

  input="$(echo "${input:-}" | tr -d '[:space:]')"

  if [[ -z "$input" ]]; then
    if [[ "$mode" == "install" ]]; then
      ok "Канал не ограничиваем."
    else
      info "Отменено, ничего не изменено."
    fi
    return 0
  fi

  if [[ "$input" == "0" ]]; then
    bandwidth_apply ""
    return 0
  fi

  if [[ ! "$input" =~ ^[0-9]+$ ]] || (( 10#$input < 1 || 10#$input > 100000 )); then
    warn "Некорректная скорость. Нужно целое число от 1 до 100000 (Мбит/с)."
    return 1
  fi

  bandwidth_apply "$((10#$input))"
}

manage_bandwidth() {
  need_root
  section "Ограничение канала (исходящая скорость)"

  bandwidth_status
  bandwidth_prompt menu || true

  echo
  bandwidth_status
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
    # Установка идёт тихо (вывод в лог): прогресс-бары apt и packagecloud-скрипта
    # перехватывают терминал и портят дальнейший вывод. timeout не даёт зависнуть
    # навсегда, но берём с запасом — триггеры man-db после установки пакета
    # спокойно идут пару минут, а прежние 150с их обрывали и шаг падал с [FAIL],
    # хотя пакет по факту уже ставился.
    run_shell "Подключаю репозиторий Ookla Speedtest" \
      "set -o pipefail; timeout 300 bash -c 'curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash'" || true
    run_shell "Устанавливаю Ookla speedtest" \
      "timeout 600 env DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest" || true
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
    run_live_cancellable "Ookla Speedtest (ближайший сервер)" \
      "speedtest --accept-license --accept-gdpr 2>/dev/null || speedtest" 45
  else
    run_live_cancellable "Speedtest (speedtest-cli)" "speedtest-cli" 45
  fi
}

# Если на сервере уже есть прошлая установка (нода Remnawave, контейнеры
# Caddy/selfsteal), предлагает остановить/удалить их перед новой установкой,
# чтобы не конфликтовали порты и старые процессы. По умолчанию — не трогать.
offer_cleanup_previous() {
  command -v docker >/dev/null 2>&1 || return 0

  local d node_dirs=() caddy_ctrs
  for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
    [[ -f "$d/docker-compose.yml" ]] || continue
    grep -q 'remnawave/node' "$d/docker-compose.yml" 2>/dev/null && node_dirs+=("$d")
  done

  caddy_ctrs="$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null \
    | grep -iE 'caddy|selfsteal|steal' | awk '{print $1}' | sort -u || true)"

  # Есть ли вообще что чистить?
  [[ ${#node_dirs[@]} -gt 0 || -n "$caddy_ctrs" ]] || return 0

  section "Обнаружена предыдущая установка"
  [[ ${#node_dirs[@]} -gt 0 ]] && info "Ноды Remnawave: ${node_dirs[*]}"
  [[ -n "$caddy_ctrs" ]] && info "Контейнеры Caddy/selfsteal: $(echo "$caddy_ctrs" | tr '\n' ' ')"
  echo
  info "Можно остановить/удалить прошлое, чтобы освободить порты и не мешать новой установке."
  ask ans "  Очистить предыдущую установку? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да) ;;
    *) ok "Оставляю прошлую установку как есть."; return 0 ;;
  esac

  local nd c
  for nd in "${node_dirs[@]}"; do
    run_shell "Останавливаю ноду в $nd" \
      "cd '$nd' && { docker compose down 2>/dev/null || docker-compose down 2>/dev/null; } || true"
  done

  if [[ -n "$caddy_ctrs" ]]; then
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      run_shell "Удаляю контейнер $c" "docker rm -f '$c' >/dev/null 2>&1 || true"
    done <<< "$caddy_ctrs"
  fi

  # На всякий случай останавливаем caddy, если он поднят как systemd-сервис.
  systemctl stop caddy >/dev/null 2>&1 || true

  ok "Предыдущая установка остановлена."
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
  ask ans "  Продолжить установку? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да) ;;
    *) die "Отменено пользователем." ;;
  esac

  offer_cleanup_previous
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

      # Ядро XanMod установлено, но GRUB загрузил другое (частое у провайдеров).
      # Перевыставляем XanMod дефолтным, чтобы следующий reboot был правильным.
      if dpkg-query -W -f='${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q "$KERNEL_VER"; then
        warn "Ядро XanMod установлено, но GRUB загрузил не его. Перевыставляю его загрузочным по умолчанию."
        if set_grub_default_to_kernel "$KERNEL_VER"; then
          warn "Готово. Чтобы получить BBR v3, перезагрузи сервер ещё раз (reboot) и снова зайди по SSH — установка продолжится."
          echo
          ask reboot_ans "  Перезагрузить сейчас, чтобы загрузиться в XanMod? [y/N]: "
          case "${reboot_ans,,}" in
            y|yes|д|да)
              set_state "need_post_reboot"
              install_profile_continue_hook
              info "Перезагружаюсь. После входа по SSH установка продолжится автоматически."
              sleep 3
              reboot || warn "reboot вернул ошибку — перезагрузи сервер вручную."
              ;;
            *)
              warn "Продолжаю на текущем ядре. BBR v3 станет активен после reboot в XanMod."
              ;;
          esac
        else
          warn "Не удалось выставить XanMod дефолтным. Выбери его в меню GRUB (Advanced options) при следующем reboot."
        fi
      else
        warn "Продолжаю настройку, но BBR v3 может быть недоступен."
      fi
    fi
  elif uname -r | grep -q 'xanmod'; then
    ok "Загружено ядро XanMod: $(uname -r)"
  else
    warn "Загружено не XanMod-ядро: $(uname -r). Продолжаю, но BBR v3 может быть недоступен."
  fi

  apply_network_tuning
  apply_system_limits
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

# Установка ТОЛЬКО ноды: Docker, транспорт (REALITY/TLS) и сам контейнер
# Remnawave Node с конфигом. Без XanMod-ядра, sysctl-тюнинга, лимитов, THP/RPS,
# LLMNR и без reboot.
#
# Зачем отдельный пункт: тюнинг из полного сценария либо уже сделан (нода
# переустанавливается на настроенном сервере), либо неприменим/нежелателен —
# LXC/OpenVZ с ядром хоста, арендованный сервер со своим ядром, площадка, где
# reboot стоит дорого. Раньше в таких случаях приходилось идти полным
# сценарием и вручную отказываться от каждого шага.
install_node_only() {
  need_root
  print_banner
  save_self
  ensure_eclipse_command

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  NODE_ONLY=1

  section "Установка ноды (только нода и конфиг)"
  info "Ставим: базовые пакеты, Docker, транспорт (REALITY/TLS), контейнер ноды."
  info "НЕ трогаем: ядро XanMod, сетевой тюнинг, лимиты, THP/RPS, LLMNR, reboot."
  echo

  local ans
  ask ans "  Продолжить? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да) ;;
    *) NODE_ONLY=0; warn "Отменено пользователем."; return 0 ;;
  esac

  offer_cleanup_previous
  ask_node_install_type

  install_base_packages
  install_docker
  step_transport_setup
  setup_remnanode

  NODE_ONLY=0

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
  echo "  Конфиг инбаундов для панели:"
  echo "    $REMNANODE_DIR/panel-inbounds.json"
  echo

  if [[ "$NODE_INSTALL_TYPE" == "reality" && "$HYSTERIA2_ENABLED" -eq 1 && "$CERT_OK" -eq 1 ]]; then
    echo "  Конфиг инбаунда Hysteria2 для панели:"
    echo "    $REMNANODE_DIR/panel-inbound-hysteria2.json"
    echo
  fi

  info "Тюнинг не выполнялся. Полный сценарий (BBR3 + XanMod) — пункт 1 меню."
  echo "  Менеджер снова открыть командой: ${C_BOLD}eclipse${C_RESET}"
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
  7. Remnawave Node в выбранной папке (/opt/remnanode, /home/<user>/remnanode, /root/remnanode)
  8. Выбор порта и имя контейнера
  9. Финальная проверка

Быстро открыть README на сервере можно так:

  curl -fL https://raw.githubusercontent.com/blantxxv/bbr3/main/README.md | less

EOF_MANUAL
}

pause_menu() {
  echo
  local _unused
  ask _unused "  Нажми Enter для возврата в меню..." || true
}

# ============================================================================
# Eclipse Firewall (nftables) — защита ноды.
#
# Живёт в СВОЕЙ таблице `inet na_filter` и НЕ делает flush ruleset, поэтому
# сосуществует с UFW, Docker и CrowdSec (каждый — свои таблицы/цепочки).
# Ключевая фича: порт ноды (NODE_PORT) открывается ТОЛЬКО для IP панели
# (резолвится из домена панели, обновляется systemd-таймером). Плюс per-IP
# анти-флуд (SYN/UDP/ICMP), connlimit, anti-spoof bogon, drop битых TCP-флагов
# и бан SSH connect-flood. Policy = accept: наша таблица только ДОБАВЛЯет drop'ы
# к тому, что уже есть, а «строгий» режим добавляет финальный drop всего лишнего.
#
# Защита от самоблокировки: IP текущей SSH-сессии авто-вайтлистится, а при
# включении правила применяются с авто-откатом через 180с, если пользователь
# не подтвердит, что связь жива.
# ============================================================================

# ECLIPSE_FW_DIR задан в блоке констант в начале файла (на него ссылаются
# присваивания верхнего уровня из секций выше).
ECLIPSE_FW_FILE="$ECLIPSE_FW_DIR/na_filter.nft"
ECLIPSE_FW_MODE_FILE="$ECLIPSE_FW_DIR/fw_mode"
ECLIPSE_PANEL_DOMAIN_FILE="$ECLIPSE_FW_DIR/panel_domain"
ECLIPSE_PANEL_SYNC="/usr/local/sbin/eclipse-panel-sync.sh"

# Лимиты (взяты из node-accelerator, per-IP — масштабируются по числу клиентов,
# а не глобальный потолок).
NA_SYN_RATE="200/second"
NA_UDP_RATE="200/second"
NA_ICMP_RATE="10/second"
NA_CONN_LIMIT="2048"
NA_SSH_FLOOD_RATE="6/minute"

na_ensure_nftables() {
  if command -v nft >/dev/null 2>&1; then
    return 0
  fi
  run_cmd "Устанавливаю nftables" env DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
}

# Основной (WAN) интерфейс — на нём полицируем трафик. Всё остальное (lo,
# docker*, туннели) наша таблица пропускает, чтобы не ломать контейнеры.
na_detect_wan() {
  local i
  i="$(detect_iface)"
  echo "${i:-eth0}"
}

# SSH-порт(ы): из sshd_config + порт текущего соединения (SSH_CONNECTION).
na_detect_ssh_ports() {
  local ports=() p conn
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
  done < <(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    conn="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
    [[ "$conn" =~ ^[0-9]+$ ]] && ports+=("$conn")
  fi

  [[ ${#ports[@]} -eq 0 ]] && ports=(22)
  printf '%s\n' "${ports[@]}" | sort -un | xargs
}

# IP клиента текущей SSH-сессии (для авто-вайтлиста, анти-самоблокировка).
na_detect_ssh_client_ip() {
  local ips=()
  [[ -n "${SSH_CONNECTION:-}" ]] && ips+=("$(awk '{print $1}' <<< "$SSH_CONNECTION")")
  [[ -n "${SSH_CLIENT:-}" ]] && ips+=("$(awk '{print $1}' <<< "$SSH_CLIENT")")
  printf '%s\n' "${ips[@]}" | awk 'NF' | sort -u | xargs
}

# Порт(ы) установленных нод (NODE_PORT из .env). Фоллбэк — известные дефолты
# node-agent'а (2222 старый, 3000 новый).
na_detect_node_ports() {
  local d port found=()
  for d in /opt/remnanode /root/remnanode /home/*/remnanode /opt/*-Node; do
    [[ -f "$d/.env" ]] || continue
    port="$(grep -E '^NODE_PORT=' "$d/.env" 2>/dev/null | head -n1 | cut -d= -f2 | tr -d '[:space:]')"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && found+=("$port")
  done
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "2222 3000"
  else
    printf '%s\n' "${found[@]}" | sort -un | xargs
  fi
}

na_resolve_domain_v4() {
  local domain="$1" out
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    [[ -z "$out" ]] && out="$(dig +short A "$domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    echo "$out"
  else
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

na_resolve_domain_v6() {
  local domain="$1"
  command -v dig >/dev/null 2>&1 || return 0
  dig +short AAAA "$domain" @1.1.1.1 2>/dev/null | grep -E ':' || true
}

# Генерирует файл ruleset. Режим: strict (блокировать всё лишнее) или open
# (пропускать всё лишнее, но с анти-флудом). Порт ноды ограничивается панелью,
# только если задан домен панели (иначе оставляем открытым, чтобы включение
# фаервола не оборвало связь панели с нодой).
na_write_ruleset() {
  local mode="$1"
  local wan ssh_ports node_ports ssh_ips ssh_set node_set
  local wl4=() wl6=() ip wl4_elems="" wl6_elems="" panel_only=0 final_rule=""

  mkdir -p "$ECLIPSE_FW_DIR"

  wan="$(na_detect_wan)"
  ssh_ports="$(na_detect_ssh_ports)"
  node_ports="$(na_detect_node_ports)"
  ssh_ips="$(na_detect_ssh_client_ip)"

  ssh_set="$(echo "$ssh_ports" | tr ' ' ',')"
  node_set="$(echo "$node_ports" | tr ' ' ',')"

  for ip in $ssh_ips; do
    if [[ "$ip" == *:* ]]; then wl6+=("$ip"); else wl4+=("$ip"); fi
  done
  [[ ${#wl4[@]} -gt 0 ]] && wl4_elems=" elements = { $(IFS=,; echo "${wl4[*]}") }"
  [[ ${#wl6[@]} -gt 0 ]] && wl6_elems=" elements = { $(IFS=,; echo "${wl6[*]}") }"

  [[ -s "$ECLIPSE_PANEL_DOMAIN_FILE" ]] && panel_only=1
  [[ "$mode" == "strict" ]] && final_rule="    drop"

  # Правила для порта ноды: с панелью — только её IP, без панели — открыто.
  local nodeport_block
  if [[ "$panel_only" -eq 1 ]]; then
    nodeport_block="    tcp dport { $node_set } ip saddr @nodeport_wl_v4 accept
    tcp dport { $node_set } ip6 saddr @nodeport_wl_v6 accept
    tcp dport { $node_set } drop"
  else
    nodeport_block="    tcp dport { $node_set } accept"
  fi

  cat > "$ECLIPSE_FW_FILE" <<NFT
#!/usr/sbin/nft -f
# Eclipse Firewall — таблица inet na_filter. Сгенерировано автоматически.
# Режим: $mode · WAN: $wan · SSH: $ssh_ports · NODE: $node_ports · panel_only=$panel_only
table inet na_filter
delete table inet na_filter
table inet na_filter {
  set wl_v4 { type ipv4_addr; flags interval;$wl4_elems }
  set wl_v6 { type ipv6_addr; flags interval;$wl6_elems }
  set nodeport_wl_v4 { type ipv4_addr; flags interval; }
  set nodeport_wl_v6 { type ipv6_addr; flags interval; }
  set bogon_v4 { type ipv4_addr; flags interval; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4 } }
  set ssh_ban_v4 { type ipv4_addr; flags dynamic, timeout; timeout 1h; }

  chain input {
    type filter hook input priority 0; policy accept;

    ct state established,related accept
    iif "lo" accept
    ct state invalid drop

    ip saddr @wl_v4 accept
    ip6 saddr @wl_v6 accept

    # Полицируем только WAN — весь трафик с других интерфейсов (docker, туннели)
    # пропускаем к остальным таблицам (UFW/Docker решают сами).
    iifname != "$wan" accept

    # anti-spoof: bogon/RFC1918/CGNAT как источник на WAN.
    ip saddr @bogon_v4 drop

    # drop битых комбинаций TCP-флагов (сканы).
    tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 drop
    tcp flags & (fin|syn) == (fin|syn) drop
    tcp flags & (syn|rst) == (syn|rst) drop
    tcp flags & (fin|rst) == (fin|rst) drop
    tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|psh|urg) drop

    # ICMP: пинг жив, флуд режется. ICMPv6 не трогаем (нужен для ND).
    ip protocol icmp icmp type echo-request limit rate $NA_ICMP_RATE accept
    ip protocol icmp icmp type echo-request drop
    meta l4proto ipv6-icmp accept

    # SSH: бан connect-flood (наш IP уже в wl_v4 выше — нас не забанит).
    ip saddr @ssh_ban_v4 drop
    tcp dport { $ssh_set } ct state new update @ssh_ban_v4 { ip saddr limit rate over $NA_SSH_FLOOD_RATE } drop
    tcp dport { $ssh_set } accept

    # Порт ноды — только для панели (если задан домен панели).
$nodeport_block

    # per-IP анти-флуд для всех новых соединений на WAN.
    tcp flags syn ct state new meter na_syn4 { ip saddr limit rate over $NA_SYN_RATE } drop
    ct state new meter na_conn4 { ip saddr ct count over $NA_CONN_LIMIT } drop
    meta l4proto udp meter na_udp4 { ip saddr limit rate over $NA_UDP_RATE } drop

    # Публичные сервис-порты.
    tcp dport { 80, 443 } accept
    udp dport { 443 } accept

$final_rule
  }
}
NFT
}

# Скрипт периодической ре-резолвинга домена панели → обновление nodeport_wl_*.
na_write_sync_script() {
  cat > "$ECLIPSE_PANEL_SYNC" <<'SYNC'
#!/usr/bin/env bash
# Резолвит домен панели и держит в nodeport_wl_v4/v6 актуальные IP панели.
set -u
DOMAIN_FILE="/etc/eclipse/panel_domain"
DOMAIN="$(cat "$DOMAIN_FILE" 2>/dev/null || true)"
[ -n "$DOMAIN" ] || exit 0
command -v nft >/dev/null 2>&1 || exit 0
nft list table inet na_filter >/dev/null 2>&1 || exit 0

resolve4() {
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    dig +short A "$1" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  else
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}'
  fi
}
resolve6() {
  command -v dig >/dev/null 2>&1 || return 0
  dig +short AAAA "$1" @1.1.1.1 2>/dev/null | grep -E ':'
}

v4="$(resolve4 "$DOMAIN" | sort -u)"
v6="$(resolve6 "$DOMAIN" | sort -u)"

# Пустой ответ DNS не сбрасываем — оставляем прежние IP (защита от временного
# сбоя резолва, чтобы не оборвать панель).
[ -n "$v4$v6" ] || exit 0

nft flush set inet na_filter nodeport_wl_v4 2>/dev/null || true
nft flush set inet na_filter nodeport_wl_v6 2>/dev/null || true
for ip in $v4; do nft add element inet na_filter nodeport_wl_v4 "{ $ip }" 2>/dev/null || true; done
for ip in $v6; do nft add element inet na_filter nodeport_wl_v6 "{ $ip }" 2>/dev/null || true; done
logger -t eclipse-panel-sync "synced $DOMAIN -> v4=[$(echo $v4 | tr '\n' ' ')] v6=[$(echo $v6 | tr '\n' ' ')]" 2>/dev/null || true
exit 0
SYNC
  chmod 755 "$ECLIPSE_PANEL_SYNC"
}

# systemd-юниты: сервис применения фаервола при загрузке + таймер ре-резолва.
na_install_units() {
  local nft_bin
  nft_bin="$(command -v nft || echo /usr/sbin/nft)"

  cat > /etc/systemd/system/eclipse-firewall.service <<EOF_FWSVC
[Unit]
Description=Eclipse nftables firewall (na_filter)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft_bin -f $ECLIPSE_FW_FILE
ExecStartPost=-$ECLIPSE_PANEL_SYNC
ExecStop=-$nft_bin delete table inet na_filter

[Install]
WantedBy=multi-user.target
EOF_FWSVC

  cat > /etc/systemd/system/eclipse-panel-sync.service <<EOF_SYNCSVC
[Unit]
Description=Eclipse panel IP sync (nodeport whitelist)
After=eclipse-firewall.service

[Service]
Type=oneshot
ExecStart=$ECLIPSE_PANEL_SYNC
EOF_SYNCSVC

  cat > /etc/systemd/system/eclipse-panel-sync.timer <<'EOF_SYNCTIMER'
[Unit]
Description=Eclipse panel IP sync timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF_SYNCTIMER

  systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
}

# Применяет ruleset с авто-откатом (анти-самоблокировка).
na_apply_with_rollback() {
  local nft_bin ans pid
  nft_bin="$(command -v nft)"

  if ! "$nft_bin" -f "$ECLIPSE_FW_FILE"; then
    fail "Не удалось применить nftables ruleset. Проверь $ECLIPSE_FW_FILE и $LOG_FILE."
    return 1
  fi
  ok "Правила применены (таблица inet na_filter)."

  # Полностью отвязываем дескрипторы фонового «сторожа», чтобы он не держал
  # терминал/канал открытым (иначе в некоторых окружениях скрипт «висит»).
  ( sleep 180; "$nft_bin" delete table inet na_filter >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true

  echo
  warn "АНТИ-САМОБЛОКИРОВКА: если связь оборвётся — просто НЕ подтверждай."
  warn "Через 180 секунд фаервол автоматически откатится (таблица удалится)."
  echo
  ask ans "  Связь работает нормально, оставить фаервол включённым? [y/N]: "

  case "${ans,,}" in
    y|yes|д|да)
      kill "$pid" >/dev/null 2>&1 || true
      systemctl enable eclipse-firewall.service >> "$LOG_FILE" 2>&1 || true
      ok "Фаервол включён и будет применяться при загрузке (eclipse-firewall.service)."
      ;;
    *)
      kill "$pid" >/dev/null 2>&1 || true
      "$nft_bin" delete table inet na_filter >/dev/null 2>&1 || true
      systemctl disable eclipse-firewall.service >> "$LOG_FILE" 2>&1 || true
      warn "Откат: таблица inet na_filter удалена, автозапуск выключен."
      return 1
      ;;
  esac
}

# Единая точка включения фаервола в режиме strict/open.
na_firewall_apply() {
  local mode="$1"

  na_ensure_nftables || { warn "nftables не установлен."; return 1; }

  na_write_ruleset "$mode"
  echo "$mode" > "$ECLIPSE_FW_MODE_FILE"

  if ! nft -c -f "$ECLIPSE_FW_FILE"; then
    fail "Сгенерированный ruleset не прошёл проверку nft -c. Не применяю."
    return 1
  fi

  na_write_sync_script
  na_install_units
  na_apply_with_rollback || return 1

  # Если домен панели задан — сразу подтягиваем его IP и включаем таймер.
  if [[ -s "$ECLIPSE_PANEL_DOMAIN_FILE" ]]; then
    "$ECLIPSE_PANEL_SYNC" || true
    systemctl enable --now eclipse-panel-sync.timer >> "$LOG_FILE" 2>&1 || true
  fi
}

na_firewall_enable_strict() {
  section "Eclipse Firewall — строгий режим (strict)"
  info "Блокируется всё, кроме: SSH, 80/443, порта ноды (для панели) и established."
  na_firewall_apply "strict"
}

na_firewall_enable_open() {
  section "Eclipse Firewall — мягкий режим (open)"
  info "Лишние порты не блокируются, но действуют per-IP анти-флуд, anti-spoof и"
  info "ограничение порта ноды для панели."
  na_firewall_apply "open"
}

# Настройка «порт ноды только для панели»: спрашиваем домен панели, резолвим,
# сохраняем и включаем фаервол (если ещё не включён — в мягком режиме).
na_set_panel_domain() {
  section "Порт ноды — доступ только для панели"

  local mode

  info "Скрипт резолвит IP домена панели и откроет порт ноды ТОЛЬКО им."
  info "Домен сохраняется в $ECLIPSE_PANEL_DOMAIN_FILE и переиспользуется в UFW."

  # Общий промпт: ввод/нормализация домена, резолв A/AAAA, сохранение.
  panel_domain_prompt || return 1

  na_ensure_nftables || { warn "nftables не установлен."; return 1; }

  mode="$(cat "$ECLIPSE_FW_MODE_FILE" 2>/dev/null || true)"
  [[ "$mode" == "strict" || "$mode" == "open" ]] || mode="open"

  info "Применяю фаервол (режим: $mode) с ограничением порта ноды для панели."
  na_firewall_apply "$mode"
}

na_firewall_status() {
  section "Eclipse Firewall — статус"

  echo
  if nft list table inet na_filter >/dev/null 2>&1; then
    ok "Таблица inet na_filter активна."
    info "Режим: $(cat "$ECLIPSE_FW_MODE_FILE" 2>/dev/null || echo неизвестен)"
    info "Домен панели: $(cat "$ECLIPSE_PANEL_DOMAIN_FILE" 2>/dev/null || echo '<не задан>')"
    echo
    echo "${C_DIM}  IP панели в whitelist (nodeport_wl_v4):${C_RESET}"
    nft list set inet na_filter nodeport_wl_v4 2>/dev/null | grep -oE 'elements = \{[^}]*\}' | sed 's/^/    /' || true
    echo
    echo "${C_DIM}  Автозапуск:${C_RESET}"
    systemctl is-enabled eclipse-firewall.service 2>/dev/null | sed 's/^/    firewall.service: /' || true
    systemctl is-enabled eclipse-panel-sync.timer 2>/dev/null | sed 's/^/    panel-sync.timer: /' || true
  else
    warn "Таблица inet na_filter не активна (фаервол выключен)."
  fi
}

na_firewall_disable() {
  section "Eclipse Firewall — выключение"

  local nft_bin ans
  nft_bin="$(command -v nft || echo nft)"

  ask ans "  Точно выключить Eclipse Firewall (удалить таблицу и автозапуск)? [y/N]: "
  case "${ans,,}" in y|yes|д|да) ;; *) info "Отменено."; return 0 ;; esac

  "$nft_bin" delete table inet na_filter >/dev/null 2>&1 || true
  systemctl disable --now eclipse-firewall.service >> "$LOG_FILE" 2>&1 || true
  systemctl disable --now eclipse-panel-sync.timer >> "$LOG_FILE" 2>&1 || true
  ok "Eclipse Firewall выключен. UFW/Docker/CrowdSec не затронуты."
}

eclipse_firewall_menu() {
  need_root

  while true; do
    clear_screen
    section "Eclipse Firewall (nftables)"
    echo
    echo "  ${C_GREEN}1${C_RESET}) Порт ноды — только для панели ${C_DIM}(указать домен панели)${C_RESET}"
    echo "  ${C_CYAN}2${C_RESET}) Включить строгий режим ${C_DIM}(strict: блокировать всё лишнее)${C_RESET}"
    echo "  ${C_CYAN}3${C_RESET}) Включить мягкий режим ${C_DIM}(open: анти-флуд + порт ноды)${C_RESET}"
    echo "  ${C_CYAN}4${C_RESET}) Обновить IP панели сейчас ${C_DIM}(ре-резолв домена)${C_RESET}"
    echo "  ${C_CYAN}5${C_RESET}) Статус фаервола"
    echo "  ${C_RED}6${C_RESET}) Выключить фаервол"
    echo "  ${C_YELLOW}0${C_RESET}) Назад"
    echo

    local choice
    ask choice "  Выбор [1/2/3/4/5/6/0]: " || choice="0"

    case "${choice:-}" in
      [1-6]) clear_screen ;;
    esac

    case "${choice:-}" in
      1) na_set_panel_domain; pause_menu ;;
      2) na_firewall_enable_strict; pause_menu ;;
      3) na_firewall_enable_open; pause_menu ;;
      4)
        if [[ -s "$ECLIPSE_PANEL_DOMAIN_FILE" ]]; then
          na_write_sync_script
          if "$ECLIPSE_PANEL_SYNC"; then ok "IP панели обновлены."; else warn "Не удалось обновить (фаервол выключен или DNS недоступен)."; fi
        else
          warn "Домен панели не задан. Сначала пункт 1."
        fi
        pause_menu
        ;;
      5) na_firewall_status; pause_menu ;;
      6) na_firewall_disable; pause_menu ;;
      0|q|Q) return 0 ;;
      *) warn "Неверный выбор: ${choice:-empty}"; sleep 1 ;;
    esac
  done
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
    echo "  ${C_CYAN}7${C_RESET}) Torrent Guard: анти-торрент ${C_DIM}(nDPI + Suricata + бан клиентов)${C_RESET}"
    echo "  ${C_CYAN}8${C_RESET}) Обновление ядра Xray"
    echo "  ${C_CYAN}9${C_RESET}) Настройка портов (UFW)"
    echo "  ${C_CYAN}10${C_RESET}) Eclipse Firewall (nftables): порт ноды для панели + защита"
    echo "  ${C_CYAN}11${C_RESET}) Ограничение канала ${C_DIM}(исходящая скорость, Мбит/с)${C_RESET}"
    echo "  ${C_GREEN}12${C_RESET}) Установка ноды ${C_DIM}(только нода и конфиг, без тюнингов)${C_RESET}"
    echo "  ${C_YELLOW}0${C_RESET}) Выход"
    echo

    ask choice "  Выбор [1..12/0]: " || choice="0"

    # Перед выполнением пункта чистим экран, чтобы на нём остался только вывод
    # этого пункта. Неверный выбор сюда не попадает — его предупреждение должно
    # быть видно на фоне меню.
    case "${choice:-}" in
      [1-9]|1[0-2]) clear_screen ;;
    esac

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
        torrent_guard_menu
        ;;
      8)
        update_xray_core
        pause_menu
        ;;
      9)
        manage_firewall
        pause_menu
        ;;
      10)
        eclipse_firewall_menu
        ;;
      11)
        manage_bandwidth
        pause_menu
        ;;
      12)
        install_node_only
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
  --node-only|--node|node-only)
    install_node_only
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
  --torrent-guard|torrent-guard)
    need_root
    torrent_guard_menu
    ;;
  --torrent-blocker|torrent-blocker)
    need_root
    install_torrent_guard_all
    ;;
  --torrent-status|torrent-status)
    need_root
    torrent_guard_status
    ;;
  --logrotate|logrotate)
    need_root
    install_log_rotation
    ;;
  --bandwidth|--limit|bandwidth|limit)
    need_root
    manage_bandwidth
    ;;
  --xray-core|--update-xray|xray-core)
    need_root
    update_xray_core
    ;;
  --firewall|--ufw|firewall|ufw)
    need_root
    manage_firewall
    ;;
  --nftables|--eclipse-firewall|nftables|eclipse-firewall)
    need_root
    eclipse_firewall_menu
    ;;
  --panel-port|panel-port)
    need_root
    na_set_panel_domain
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
  $0 --node-only        установить только ноду и конфиг, без тюнингов
  $0 --continue         продолжить после reboot
  $0 --manual           показать ручной режим
  $0 --warp             запустить настройку WARP
  $0 --check-update     проверить обновления
  $0 --test             проверить систему
  $0 --torrent-guard    меню Torrent Guard (анти-торрент)
  $0 --torrent-blocker  установить/обновить оба слоя Torrent Guard
  $0 --torrent-status   статус анти-торрент защиты
  $0 --logrotate        настроить суточную ротацию логов ноды и менеджера
  $0 --bandwidth        ограничение исходящей скорости (Мбит/с)
  $0 --xray-core        обновить ядро Xray в контейнере ноды
  $0 --firewall         настройка портов (UFW)
  $0 --panel-port       порт ноды только для панели (nftables)

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
