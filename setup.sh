#!/bin/bash
# ============================================================
#  Скрипт базовой настройки и hardening Linux-сервера
#  Поддержка: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Запуск: строго от имени root
#
#  Использование:
#    ./setup.sh           # полный прогон
#    ./setup.sh --check   # только предварительный анализ, без изменений
#    ./setup.sh -c        # короткий синоним --check
#
#  Репозиторий: https://github.com/thealekseev/vps-setup
# ============================================================

set -uo pipefail

# ---------- Разбор аргументов ----------
CHECK_MODE=0
case "${1:-}" in
    --check|-c) CHECK_MODE=1 ;;
esac

# ---------- Цвета для вывода ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   NC='\033[0m'

# ---------- Логирование ----------
LOG_FILE="/var/log/server-hardening.log"

exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

SPINNER_ENABLED=0
if [ -t 3 ]; then
    SPINNER_ENABLED=1
fi

SCRIPT_START=$(date +%s)

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# Глобальный обработчик ошибок.
trap 'err "Непредвиденная ошибка в строке $LINENO. Лог: $LOG_FILE. Соединение НЕ перезапущено. Проверьте: sshd -t"' ERR

# ---------- Управление шагами ----------
STEP=0; TOTAL_STEPS=10; START_TIME=0

step_start() {
    STEP=$((STEP + 1))
    local width=20
    local filled=$(( STEP * width / TOTAL_STEPS ))
    local percent=$(( STEP * 100 / TOTAL_STEPS ))
    local bar="" i
    for ((i=0; i<width; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
    done
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  [$STEP/$TOTAL_STEPS] ${GREEN}${bar}${NC} ${YELLOW}${percent}%${NC} $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    START_TIME=$(date +%s)
}

_heartbeat() {
    local desc="$1"
    local start="$2"
    local tick=0
    local now elapsed
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local n=${#frames[@]}
    while :; do
        if [ "$SPINNER_ENABLED" -eq 1 ]; then
            now=$(date +%s)
            elapsed=$((now - start))
            printf '\r\033[K  %b%s%b %s — %s сек.' \
                "${CYAN}" "${frames[$((tick % n))]}" "${NC}" \
                "$desc" "$elapsed" >&3 2>/dev/null || return 0
            tick=$((tick + 1))
            sleep 0.15
        else
            sleep 10
            tick=$((tick + 1))
            now=$(date +%s)
            elapsed=$((now - start))
            if [ $((tick % 6)) -eq 0 ]; then
                printf '  … %s — всё ещё выполняется (%s сек.)\n' \
                    "$desc" "$elapsed" || true
            fi
        fi
    done
}

run_timed() {
    local desc="$1"; shift
    local start end rc hb_pid
    echo -e "  ${CYAN}↳${NC} $desc"
    start=$(date +%s)

    _heartbeat "$desc" "$start" &
    hb_pid=$!

    rc=0
    "$@" >> "$LOG_FILE" 2>&1 || rc=$?

    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true

    if [ "$SPINNER_ENABLED" -eq 1 ]; then
        printf '\r\033[K' >&3 2>/dev/null || true
    fi

    end=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} $desc — $((end - start)) сек."
    else
        echo -e "  ${RED}✗${NC} $desc — $((end - start)) сек. (exit $rc)"
    fi
    return "$rc"
}

step_done() {
    local END_TIME; END_TIME=$(date +%s)
    echo -e "${GREEN}  [OK] Шаг завершён за $((END_TIME - START_TIME)) сек.${NC}"
}

# ---------- Вспомогательные функции ----------
confirm() {
    local prompt="$1" answer
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer < /dev/tty || true
    [[ "$answer" =~ ^[Yy]$ ]]
}

pad_right() {
    local s="$1" width="$2"
    local padding=$(( width - ${#s} ))
    [ "$padding" -lt 0 ] && padding=0
    printf '%s%*s' "$s" "$padding" ""
}

backup_file() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.bak.initial" ]; then
        cp -a "$file" "${file}.bak.initial"
        info "Создана резервная копия: ${file}.bak.initial"
    fi
}

validate_username() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    [ "${#name}" -le 32 ] || return 1
    case "$name" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|sshd|ubuntu|debian)
            return 1 ;;
    esac
    return 0
}

sshd_current() {
    local key="$1"
    local val=""
    val="$(sshd -T 2>/dev/null | awk -v k="$key" 'tolower($1)==k {print $2; exit}' || true)"
    printf '%s' "$val"
    return 0
}

# Возвращает порт, который sshd реально слушает прямо сейчас (Local Address:Port).
# Парсим `ss -tlnp` — там Local Address в 4-м поле, фильтруем по процессу sshd.
sshd_listening_port() {
    local p=""
    p="$(ss -tlnp 2>/dev/null \
        | awk '/sshd/ {print $4}' \
        | head -n1 \
        | rev | cut -d: -f1 | rev)" || true
    printf '%s' "${p:-}"
}

# Проверяет, слушается ли данный TCP-порт (0.0.0.0:PORT, [::]:PORT и т.п.).
# БЕЗ pipe в grep -q, чтобы не ловить SIGPIPE + pipefail.
port_is_listening() {
    local port="$1"
    local out
    out="$(ss -tln 2>/dev/null || true)"
    grep -q ":${port} " <<< "$out"
}

# Проверяет, сконфигурировано ли в UFW правило для данного порта/tcp.
# ВАЖНО: `ufw status` при выключенном UFW показывает только "Status: inactive",
# без списка правил. `ufw show added` показывает сконфигурированные правила.
# Читаем вывод в переменную, чтобы не зависеть от pipefail + grep -q.
ufw_has_rule() {
    local port="$1"
    local rules
    rules="$(ufw show added 2>/dev/null)" || rules=""
    grep -Eq "${port}/tcp([[:space:]]|$)" <<< "$rules"
}

# Универсальный детектор SSH-юнита.
# ВАЖНО: раньше был `systemctl list-unit-files | grep -q '^ssh\.service'`.
# При `set -o pipefail` это ломается: grep -q находит совпадение и выходит,
# не дочитав вход; systemctl получает SIGPIPE (exit 141), и pipefail делает
# весь pipeline неуспешным — даже если совпадение было. Поэтому обе ветки
# if/elif проваливаются, и функция ошибочно сообщает «Не найден сервис».
# `systemctl cat` не использует pipe и возвращает 0 ровно тогда, когда юнит
# существует.
detect_ssh_unit() {
    local candidate
    for candidate in ssh sshd; do
        if systemctl cat "${candidate}.service" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# Перезапускает SSH. Гарантирует, что:
#   • ssh.socket погашен (иначе Port в sshd_config игнорируется);
#   • выполнен именно restart, а не reload;
#   • процесс sshd действительно поднялся.
service_restart_or_reload_ssh() {
    local unit
    unit="$(detect_ssh_unit)" || {
        err "Не найден сервис ssh/sshd (systemctl cat ssh.service/sshd.service — 0 совпадений)"
        err "Диагностика:"
        err "  systemctl list-unit-files --no-pager | grep -E 'ssh|sshd'"
        err "  systemctl status ssh.socket ssh.service 2>/dev/null"
        return 1
    }

    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        log "Обнаружен активный ssh.socket — отключаем (иначе Port игнорируется)."
        systemctl disable --now ssh.socket 2>/dev/null \
            || warn "disable --now ssh.socket вернул ошибку (продолжаем)"
        sleep 1
    fi

    sshd -t || { err "sshd -t не проходит. Перезапуск отменён."; return 1; }

    if systemctl restart "$unit" 2>/dev/null; then
        log "SSH перезапущен (restart, $unit)"
        local i
        for i in $(seq 1 10); do
            if pgrep -x sshd >/dev/null 2>&1; then
                sleep 1
                return 0
            fi
            sleep 0.5
        done
        return 0
    fi

    err "Не удалось перезапустить SSH!"; return 1
}

get_public_ip() {
    curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
      || echo "unknown"
}

# ============================================================
#  0. Проверки окружения
# ============================================================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Запустите скрипт от имени root"; exit 1
fi
[ -f /etc/os-release ] || { err "/etc/os-release отсутствует"; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"
case "$OS_ID" in
    ubuntu|debian) : ;;
    *) warn "ОС '$OS_ID' не тестировалась"; confirm "Продолжить?" || exit 1 ;;
esac
log "ОС: ${PRETTY_NAME:-$OS_ID $OS_VER}"
export DEBIAN_FRONTEND=noninteractive

log "Проверка блокировки dpkg..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "dpkg занят фоновыми процессами (cloud-init), ждём 10 сек..."; sleep 10
done

# ============================================================
#  1. Предварительный анализ системы
# ============================================================
step_start "Предварительный анализ системы"

CUR_SSH_PORT="$(sshd_current port || true)";  CUR_SSH_PORT="${CUR_SSH_PORT:-22}"
CUR_PERMIT_ROOT_LOGIN="$(sshd_current permitrootlogin || true)"
CUR_PASSWORD_AUTH="$(sshd_current passwordauthentication || true)"
CUR_PUBKEY_AUTH="$(sshd_current pubkeyauthentication || true)"

CUR_ALLOW_USERS="$(sshd -T 2>/dev/null \
    | awk '$1=="allowusers" {$1=""; sub(/^ +/,""); print; exit}' || true)"

CUR_KEYS_ROOT="нет"
[ -s /root/.ssh/authorized_keys ] && CUR_KEYS_ROOT="есть"

declare -a CUR_KEYED_USERS=()
shopt -s nullglob
for d in /home/*/.ssh/authorized_keys; do
    [ -s "$d" ] || continue
    local_u="$(basename "$(dirname "$(dirname "$d")")" || true)"
    [ -n "$local_u" ] && CUR_KEYED_USERS+=("$local_u")
done
shopt -u nullglob

# ssh.socket может быть активен, не будучи enabled. Проверяем оба состояния.
CUR_SSH_SOCKET="нет"
SSH_USES_SOCKET=0
if systemctl is-enabled --quiet ssh.socket 2>/dev/null \
   || systemctl is-active  --quiet ssh.socket 2>/dev/null; then
    CUR_SSH_SOCKET="да (Ubuntu 22.10+/Debian 12+)"
    SSH_USES_SOCKET=1
fi

CUR_UFW_STATUS="$(ufw status 2>/dev/null | awk 'NR==1 {print $2}' || true)"
CUR_UFW_STATUS="${CUR_UFW_STATUS:-не установлен}"

CUR_F2B_STATUS="$(systemctl is-active fail2ban 2>/dev/null || true)"
CUR_F2B_STATUS="${CUR_F2B_STATUS:-inactive}"

CUR_SWAP="нет"
[ -n "$(swapon --show 2>/dev/null || true)" ] && CUR_SWAP="есть"
CUR_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
CUR_TZ="${CUR_TZ:-unknown}"

LABEL_WIDTH=26

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║             ТЕКУЩАЯ КОНФИГУРАЦИЯ СИСТЕМЫ                 ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}SSH:${NC}"
echo -e "    $(pad_right 'Порт:'                     $LABEL_WIDTH)${CUR_SSH_PORT}"
echo -e "    $(pad_right 'PermitRootLogin:'          $LABEL_WIDTH)${CUR_PERMIT_ROOT_LOGIN:-<не задан>}"
echo -e "    $(pad_right 'PasswordAuthentication:'   $LABEL_WIDTH)${CUR_PASSWORD_AUTH:-<не задан>}"
echo -e "    $(pad_right 'PubkeyAuthentication:'     $LABEL_WIDTH)${CUR_PUBKEY_AUTH:-<не задан>}"
echo -e "    $(pad_right 'ssh.socket:'               $LABEL_WIDTH)${CUR_SSH_SOCKET}"
echo ""
echo -e "  ${YELLOW}SSH-ключи:${NC}"
echo -e "    $(pad_right 'root:'                     $LABEL_WIDTH)${CUR_KEYS_ROOT}"
if [ ${#CUR_KEYED_USERS[@]} -gt 0 ]; then
    for u in "${CUR_KEYED_USERS[@]}"; do
        echo -e "    $(pad_right "${u}:" $LABEL_WIDTH)есть"
    done
else
    echo -e "    $(pad_right 'в /home/*/.ssh:' $LABEL_WIDTH)нет"
fi
echo ""
echo -e "  ${YELLOW}Firewall и защита:${NC}"
echo -e "    $(pad_right 'UFW:'                      $LABEL_WIDTH)${CUR_UFW_STATUS}"
echo -e "    $(pad_right 'Fail2ban:'                 $LABEL_WIDTH)${CUR_F2B_STATUS}"
echo ""
echo -e "  ${YELLOW}Прочее:${NC}"
echo -e "    $(pad_right 'Swap:'                     $LABEL_WIDTH)${CUR_SWAP}"
echo -e "    $(pad_right 'Временная зона:'           $LABEL_WIDTH)${CUR_TZ}"
echo ""

step_done

# ============================================================
#  Ранний выход в режиме --check
# ============================================================
if [ "$CHECK_MODE" -eq 1 ]; then
    echo ""
    info "Режим --check: анализ завершён, изменения не вносились."
    echo -e "  ${YELLOW}Для полного прогона запустите:${NC} sudo $0"
    echo ""
    exec 1>&3 2>&1
    wait 2>/dev/null || true
    exit 0
fi

# ============================================================
#  2. Обновление системы
# ============================================================
step_start "Обновление пакетов"
run_timed "apt-get update"   apt-get update -y  || true
run_timed "apt-get upgrade"  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" upgrade || true
run_timed "autoremove"       apt-get -y autoremove || true
run_timed "autoclean"        apt-get -y autoclean  || true
step_done

# ============================================================
#  3. Установка утилит
# ============================================================
step_start "Установка утилит"
if ! run_timed "apt-get install" apt-get install -y \
    curl wget git unzip nano htop net-tools jq \
    ufw fail2ban \
    unattended-upgrades apt-listchanges needrestart \
    chrony auditd rkhunter; then
    err "Установка пакетов провалилась. Дальнейшие шаги могут быть неполными."
    confirm "Продолжить?" || exit 1
fi

command -v ufw            >/dev/null || { err "ufw не установлен, дальше нельзя"; exit 1; }
command -v fail2ban-server >/dev/null || { err "fail2ban-server не установлен, дальше нельзя"; exit 1; }
step_done

# ============================================================
#  4. Swap и время
# ============================================================
step_start "Swap и время"
if [ -z "$(swapon --show 2>/dev/null || true)" ]; then
    warn "Swap не найден. Создаём файл подкачки 2GB..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 2GB создан."
else
    info "Swap уже настроен."
fi

if command -v timedatectl >/dev/null 2>&1; then
    CUR_TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    CUR_TZ_NOW="${CUR_TZ_NOW:-UTC}"
    info "Текущий часовой пояс: ${CUR_TZ_NOW}"

    if confirm "Сменить часовой пояс?"; then
        declare -a TZ_CHOICES=()
        TZ_CHOICES+=("${CUR_TZ_NOW}")
        if [ -n "${TZ:-}" ] && [ "$TZ" != "$CUR_TZ_NOW" ]; then
            TZ_CHOICES+=("${TZ}")
        fi
        for tz in \
            "UTC" \
            "Europe/Moscow" \
            "Europe/Kyiv" \
            "Europe/Minsk" \
            "Europe/Berlin" \
            "Europe/London" \
            "Europe/Paris" \
            "Europe/Lisbon" \
            "Asia/Almaty" \
            "Asia/Tashkent" \
            "Asia/Tbilisi" \
            "Asia/Yerevan" \
            "Asia/Dubai" \
            "Asia/Tokyo" \
            "Asia/Shanghai" \
            "Asia/Singapore" \
            "America/New_York" \
            "America/Los_Angeles" \
        ; do
            local_dup=0
            for x in "${TZ_CHOICES[@]}"; do
                [ "$x" = "$tz" ] && { local_dup=1; break; }
            done
            [ "$local_dup" -eq 0 ] && TZ_CHOICES+=("$tz")
        done

        echo ""
        echo -e "${YELLOW}Доступные варианты:${NC}"
        idx=1
        for tz in "${TZ_CHOICES[@]}"; do
            marker=""
            [ "$tz" = "$CUR_TZ_NOW" ] && marker=" ${GREEN}(текущий)${NC}"
            [ "$tz" = "${TZ:-}" ] && [ "$tz" != "$CUR_TZ_NOW" ] && marker=" ${CYAN}(из окружения TZ)${NC}"
            echo -e "  $(printf '%2d' "$idx")) ${tz}${marker}"
            idx=$((idx + 1))
        done
        echo ""
        echo -e "  ${CYAN}Введите номер из списка, либо свою зону вручную (например, Europe/Lisbon).${NC}"
        echo -e "  ${CYAN}Пустой ввод — оставить ${CUR_TZ_NOW}.${NC}"
        echo ""

        read -r -p "$(echo -e "${YELLOW}Часовой пояс: ${NC}")" TZ_INPUT < /dev/tty || true

        SELECTED_TZ=""
        if [ -z "$TZ_INPUT" ]; then
            info "Часовой пояс оставлен без изменений: ${CUR_TZ_NOW}"
            SELECTED_TZ="$CUR_TZ_NOW"
        elif [[ "$TZ_INPUT" =~ ^[0-9]+$ ]] \
             && [ "$TZ_INPUT" -ge 1 ] \
             && [ "$TZ_INPUT" -le "${#TZ_CHOICES[@]}" ]; then
            SELECTED_TZ="${TZ_CHOICES[$((TZ_INPUT - 1))]}"
        else
            SELECTED_TZ="$TZ_INPUT"
        fi

        if [ "$SELECTED_TZ" != "$CUR_TZ_NOW" ]; then
            if timedatectl list-timezones 2>/dev/null | grep -Fxq "$SELECTED_TZ"; then
                if timedatectl set-timezone "$SELECTED_TZ" 2>/dev/null; then
                    log "Часовой пояс установлен: ${SELECTED_TZ}"
                else
                    warn "Не удалось установить ${SELECTED_TZ}. Оставляем ${CUR_TZ_NOW}."
                fi
            else
                warn "Часовой пояс '${SELECTED_TZ}' не найден в базе системы."
                warn "Оставляем ${CUR_TZ_NOW}. Полный список: timedatectl list-timezones"
            fi
        else
            info "Часовой пояс не изменён: ${CUR_TZ_NOW}"
        fi
    else
        info "Часовой пояс оставлен: ${CUR_TZ_NOW}"
    fi
else
    warn "timedatectl недоступен — пропускаем настройку часового пояса"
fi

systemctl enable --now chrony 2>/dev/null \
  || systemctl enable --now systemd-timesyncd 2>/dev/null || true
step_done

# ============================================================
#  5. SSH hardening
# ============================================================
step_start "SSH hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$SSHD_DIR"

# Префикс 00 — сортируется раньше 50-cloud-init.conf и любых других drop-in.
HARDENING_CONF="${SSHD_DIR}/00-hardening.conf"
backup_file "$SSHD_CONFIG"

if [ -f "${SSHD_DIR}/99-hardening.conf" ] && [ "$HARDENING_CONF" != "${SSHD_DIR}/99-hardening.conf" ]; then
    warn "Найден устаревший ${SSHD_DIR}/99-hardening.conf — удаляем."
    rm -f "${SSHD_DIR}/99-hardening.conf"
fi

# --- 5.1. Создание non-root пользователя ---
NEW_USER=""
USER_JUST_CREATED=0
if confirm "Создать non-root пользователя с правами sudo?"; then
    while true; do
        read -r -p "$(echo -e "${YELLOW}Имя пользователя: ${NC}")" NEW_USER < /dev/tty || true
        [ -z "$NEW_USER" ] && { warn "Пустое имя."; continue; }
        validate_username "$NEW_USER" || { warn "Недопустимое имя."; continue; }
        break
    done

    if id "$NEW_USER" &>/dev/null; then
        info "Пользователь $NEW_USER уже существует."
    else
        adduser --disabled-password --gecos "" "$NEW_USER"
        USER_JUST_CREATED=1
        log "Пользователь $NEW_USER создан."
    fi

    usermod -aG sudo "$NEW_USER"
    log "Пользователь $NEW_USER добавлен в группу sudo."

    if [ "$USER_JUST_CREATED" -eq 1 ]; then
        SUDOERS_FILE="/etc/sudoers.d/90-${NEW_USER}"
        if [ ! -f "$SUDOERS_FILE" ]; then
            echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
            chown root:root "$SUDOERS_FILE"
            chmod 440 "$SUDOERS_FILE"
            log "Создан ${SUDOERS_FILE} (sudo без пароля)."
            warn "Чтобы требовать пароль для sudo: passwd ${NEW_USER} && rm ${SUDOERS_FILE}"
        fi
    fi

    if [ -s /root/.ssh/authorized_keys ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
        install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
        install -m 600 -o "$NEW_USER" -g "$NEW_USER" \
            /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
        log "SSH-ключи root скопированы пользователю $NEW_USER."
    fi
fi

# --- 5.2. SSH-ключи ---
HAS_KEYS=0
[ -s /root/.ssh/authorized_keys ] && HAS_KEYS=1
for d in /home/*/.ssh; do
    [ -d "$d" ] && [ -s "$d/authorized_keys" ] && { HAS_KEYS=1; break; }
done

DISABLE_PASSWORD="no"
if [ "$HAS_KEYS" -eq 1 ]; then
    DISABLE_PASSWORD="yes"
    info "Найдены SSH-ключи → PasswordAuthentication будет отключён."
    warn "Проверьте ДО применения, что вход по ключу работает:"
    warn "  ssh -i /путь/к/ключу <user>@<этот-IP>"
else
    warn "SSH-ключи не найдены!"
    if confirm "Сгенерировать новый ed25519-ключ?"; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        if [ ! -f /root/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" \
                -C "root@$(hostname)" </dev/null >/dev/null 2>&1
        else
            info "Ключ /root/.ssh/id_ed25519 уже существует — используем его."
        fi
        cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        KEY_FILE="/root/GENERATED_PRIVATE_KEY.txt"
        cp /root/.ssh/id_ed25519 "$KEY_FILE"; chmod 400 "$KEY_FILE"
        echo ""
        echo -e "${RED}===========================================================${NC}"
        echo -e "${RED}  Приватный ключ сохранён в: ${KEY_FILE}${NC}"
        echo -e "${RED}  СКОПИРУЙТЕ его и удалите файл после настройки клиента!${NC}"
        echo -e "${RED}===========================================================${NC}"
        echo ""
        if confirm "Вы скопировали ключ и готовы отключить вход по паролю?"; then
            DISABLE_PASSWORD="yes"
            if [ -n "$NEW_USER" ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
                install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
                install -m 600 -o "$NEW_USER" -g "$NEW_USER" \
                    /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
            fi
        else
            warn "Вход по паролю оставлен включенным."
        fi
    fi
fi

# --- 5.3. Смена порта ---
NEW_SSH_PORT=""
if confirm "Сменить стандартный SSH-порт (22)?"; then
    for _ in $(seq 1 20); do
        C=$(shuf -i 10000-60000 -n 1)
        if ! port_is_listening "$C"; then NEW_SSH_PORT="$C"; break; fi
    done
    [ -z "$NEW_SSH_PORT" ] && { err "Не удалось найти свободный порт."; exit 1; }
    log "Сгенерирован новый SSH-порт: $NEW_SSH_PORT"
fi

# --- 5.4. Определение финальных значений ---
declare -a KEYED_USERS=()
[ -s /root/.ssh/authorized_keys ] && KEYED_USERS+=("root")
[ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ] \
    && KEYED_USERS+=("$NEW_USER")

if [ ${#KEYED_USERS[@]} -eq 0 ] && [ "$DISABLE_PASSWORD" = "yes" ]; then
    warn "КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: Ни у одного пользователя нет ключей."
    warn "Вход по паролю принудительно оставлен включенным во избежание блокировки."
    DISABLE_PASSWORD="no"
fi

if [ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
    ROOT_LOGIN_VAL="no"
    ROOT_LOGIN_REASON="у ${NEW_USER} есть ключ для аварийного входа"
else
    ROOT_LOGIN_VAL="prohibit-password"
    if [ -n "$NEW_USER" ]; then
        ROOT_LOGIN_REASON="у ${NEW_USER} нет ключа — оставляем вход root по ключу"
    else
        ROOT_LOGIN_REASON="non-root пользователь не создаётся"
    fi
fi

if [ "$DISABLE_PASSWORD" = "yes" ]; then
    FINAL_PASSWORD_AUTH="no"
else
    FINAL_PASSWORD_AUTH="yes"
fi

# ============================================================
#  5.5. ПЛАН ИЗМЕНЕНИЙ SSH
# ============================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║            ПЛАН ИЗМЕНЕНИЙ SSH                            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

FINAL_PORT_PREVIEW="${NEW_SSH_PORT:-${CUR_SSH_PORT}}"

echo -e "  $(pad_right 'Параметр' 24)Было → Станет"
echo -e "  ────────────────────────────────────────────────────────"

if [ "$CUR_SSH_PORT" = "$FINAL_PORT_PREVIEW" ]; then
    echo -e "  $(pad_right 'SSH-порт' 24)${CUR_SSH_PORT} (без изменений)"
else
    echo -e "  $(pad_right 'SSH-порт' 24)${CUR_SSH_PORT} → ${FINAL_PORT_PREVIEW}"
fi

if [ "$CUR_PERMIT_ROOT_LOGIN" = "$ROOT_LOGIN_VAL" ]; then
    echo -e "  $(pad_right 'PermitRootLogin' 24)${ROOT_LOGIN_VAL} (без изменений)"
else
    echo -e "  $(pad_right 'PermitRootLogin' 24)${CUR_PERMIT_ROOT_LOGIN:-?} → ${ROOT_LOGIN_VAL}"
fi

if [ "$CUR_PASSWORD_AUTH" = "$FINAL_PASSWORD_AUTH" ]; then
    echo -e "  $(pad_right 'PasswordAuthentication' 24)${FINAL_PASSWORD_AUTH} (без изменений)"
else
    echo -e "  $(pad_right 'PasswordAuthentication' 24)${CUR_PASSWORD_AUTH:-?} → ${FINAL_PASSWORD_AUTH}"
fi

if [ -n "$NEW_USER" ]; then
    if [ -z "$CUR_ALLOW_USERS" ]; then
        echo -e "  $(pad_right 'AllowUsers' 24)<все> → ${NEW_USER}"
    elif [ "$CUR_ALLOW_USERS" = "$NEW_USER" ]; then
        echo -e "  $(pad_right 'AllowUsers' 24)${NEW_USER} (без изменений)"
    else
        echo -e "  $(pad_right 'AllowUsers' 24)${CUR_ALLOW_USERS} → ${NEW_USER}"
    fi
fi

echo -e "  ────────────────────────────────────────────────────────"
echo ""

echo -e "  ${YELLOW}Пояснения:${NC}"
echo -e "    • ${CYAN}PermitRootLogin = ${ROOT_LOGIN_VAL}${NC}"
echo -e "      ${ROOT_LOGIN_REASON}"
if [ "$DISABLE_PASSWORD" = "yes" ]; then
    echo -e "    • ${CYAN}PasswordAuthentication = no${NC}"
    echo -e "      SSH-ключи найдены (${KEYED_USERS[*]}), вход по паролю будет отключён."
    echo -e "      ${RED}⚠ Убедитесь, что вы можете войти по ключу, ДО отключения пароля!${NC}"
else
    echo -e "    • ${CYAN}PasswordAuthentication = yes${NC}"
    echo -e "      Вход по паролю остаётся разрешённым."
fi
echo ""

# --- 5.6. Финальное подтверждение ---
if ! confirm "Применить эти изменения SSH?"; then
    warn "Применение изменений SSH отменено пользователем."
    warn "Конфиг sshd НЕ изменён. Сервис не перезапущен."
    echo ""
    warn "Скрипт завершён по запросу пользователя (SSH-план отклонён)."
    exec 1>&3 2>&1
    wait 2>/dev/null || true
    exit 0
fi

# --- 5.7. Применение конфигурации SSH ---
if systemctl is-enabled --quiet ssh.socket 2>/dev/null \
   || systemctl is-active  --quiet ssh.socket 2>/dev/null; then
    log "Отключаем ssh.socket (иначе Port/Directives в sshd_config игнорируются)..."
    systemctl disable --now ssh.socket 2>/dev/null \
        || warn "disable --now ssh.socket вернул ошибку"
    systemctl enable ssh.service 2>/dev/null || true
    systemctl start  ssh.service 2>/dev/null || true
    sleep 1
fi

if [ -n "$NEW_SSH_PORT" ]; then
    echo "$NEW_SSH_PORT" > /root/.new_ssh_port
    chmod 600 /root/.new_ssh_port
fi

# --- Защита от перекрытия чужими drop-in ---
# ВАЖНО: разделитель в sed — '@', потому что в CONFLICT_KEYS используется
# символ '|' как альтернация в regex. Разделитель '|' ломает sed.
CONFLICT_KEYS='^[[:space:]]*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|AllowUsers|AllowGroups|Port)[[:space:]]'

shopt -s nullglob
for f in "${SSHD_DIR}"/*.conf; do
    [ "$f" = "$HARDENING_CONF" ] && continue
    if grep -Eq "$CONFLICT_KEYS" "$f"; then
        backup_file "$f"
        sed -i -E "s@${CONFLICT_KEYS}@# [hardening] &@" "$f"
        info "Закомментированы конфликтующие директивы в ${f}"
    fi
done
shopt -u nullglob

if grep -Eq "$CONFLICT_KEYS" "$SSHD_CONFIG"; then
    backup_file "$SSHD_CONFIG"
    sed -i -E "s@${CONFLICT_KEYS}@# [hardening] &@" "$SSHD_CONFIG"
    info "Закомментированы конфликтующие директивы в ${SSHD_CONFIG}"
fi

# --- Include в НАЧАЛО sshd_config ---
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*' "$SSHD_CONFIG"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
    info "Include добавлен в начало ${SSHD_CONFIG}"
fi

# --- Пишем наш конфиг ---
cat > "$HARDENING_CONF" <<EOF
# Сгенерировано hardening-скриптом $(date -Iseconds)

# Аутентификация
PermitRootLogin ${ROOT_LOGIN_VAL}
PasswordAuthentication ${FINAL_PASSWORD_AUTH}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
MaxStartups 10:30:60

# Прочее
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PermitEmptyPasswords no
UseDNS no
LogLevel VERBOSE
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

[ -n "$NEW_USER" ]     && echo "AllowUsers ${NEW_USER}" >> "$HARDENING_CONF"
[ -n "$NEW_SSH_PORT" ] && echo "Port ${NEW_SSH_PORT}"    >> "$HARDENING_CONF"

chown root:root "$SSHD_CONFIG" "$HARDENING_CONF"
chmod 644 "$SSHD_CONFIG"
chmod 600 "$HARDENING_CONF"

if ! sshd -t; then
    err "sshd -t не проходит. Откат hardening-конфига."
    rm -f "$HARDENING_CONF"
    exit 1
fi
log "sshd -t OK (конфиг записан, но ещё не применён)"

EXPECT_PORT="${NEW_SSH_PORT:-${CUR_SSH_PORT}}"
if ! sshd -T 2>/dev/null | awk -v p="$EXPECT_PORT" '$1=="port" {print $2}' | grep -qx "$EXPECT_PORT"; then
    warn "sshd -T не показывает порт ${EXPECT_PORT}. Возможные причины:"
    warn "  • активен ssh.socket (проверьте: systemctl status ssh.socket)"
    warn "  • Port перекрыт другим drop-in (проверьте: grep -rns '^Port' /etc/ssh/)"
fi

# --- 5.8. Перечитываем эффективные значения ---
ACTUAL_PASSWORD_AUTH="$(sshd_current passwordauthentication || true)"
ACTUAL_PERMIT_ROOT_LOGIN="$(sshd_current permitrootlogin || true)"
ACTUAL_SSH_PORT="$(sshd_current port || true)"
ACTUAL_ALLOW_USERS="$(sshd -T 2>/dev/null \
    | awk '$1=="allowusers" {$1=""; sub(/^ +/,""); print; exit}' || true)"

MISMATCH=0
if [ "$ACTUAL_PASSWORD_AUTH" != "$FINAL_PASSWORD_AUTH" ]; then
    warn "РАСХОЖДЕНИЕ: PasswordAuthentication = ${ACTUAL_PASSWORD_AUTH}, ожидалось ${FINAL_PASSWORD_AUTH}."
    warn "  Источники директивы (первое значение побеждает):"
    grep -rns --include='*.conf' --include='sshd_config' \
        '^[[:space:]]*PasswordAuthentication' \
        "$SSHD_CONFIG" "$SSHD_DIR" 2>/dev/null \
        | sed 's/^/    /' >&2 || true
    MISMATCH=1
fi
if [ "$ACTUAL_PERMIT_ROOT_LOGIN" != "$ROOT_LOGIN_VAL" ]; then
    warn "РАСХОЖДЕНИЕ: PermitRootLogin = ${ACTUAL_PERMIT_ROOT_LOGIN}, ожидалось ${ROOT_LOGIN_VAL}."
    grep -rns --include='*.conf' --include='sshd_config' \
        '^[[:space:]]*PermitRootLogin' \
        "$SSHD_CONFIG" "$SSHD_DIR" 2>/dev/null \
        | sed 's/^/    /' >&2 || true
    MISMATCH=1
fi
if [ -n "$NEW_SSH_PORT" ] && [ "$ACTUAL_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    warn "РАСХОЖДЕНИЕ: Port = ${ACTUAL_SSH_PORT}, ожидалось ${NEW_SSH_PORT}."
    warn "  Возможно, ssh.socket всё ещё активен: systemctl status ssh.socket"
    MISMATCH=1
fi
if [ "$MISMATCH" -eq 0 ]; then
    info "Эффективные значения совпадают с ожидаемыми."
else
    warn "Некоторые значения отличаются — см. предупреждения выше."
fi

step_done

# ============================================================
#  6. UFW
# ============================================================
step_start "Подготовка правил UFW"

sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw

UFW_STATUS_LINE="$(ufw status 2>/dev/null || true)"
if [[ "$UFW_STATUS_LINE" == *"Status: active"* ]]; then
    warn "UFW уже активен — команда reset удалит все текущие правила."
    if ! confirm "Сбросить существующие правила UFW и начать заново?"; then
        err "Отменено. Прервите выполнение и настройте UFW вручную."
        exit 1
    fi
fi

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming   || { err "ufw default deny incoming упал"; exit 1; }
ufw default allow outgoing  || { err "ufw default allow outgoing упал"; exit 1; }
ufw default deny routed     || { err "ufw default deny routed упал"; exit 1; }

# Определяем старый SSH-порт. Полагаемся на то, что реально слушает sshd
# прямо сейчас — это и есть порт, который нужно временно оставить открытым.
CURRENT_SSH_PORT="$(sshd_listening_port)"
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT="${CUR_SSH_PORT:-}"
fi
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
log "Текущий SSH-порт (слушает sshd): ${CURRENT_SSH_PORT}"

# Для SSH используем allow, а не limit. Rate-limit всё равно делает fail2ban.
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    ufw allow "${CURRENT_SSH_PORT}"/tcp comment 'SSH OLD (temp)' \
        || { err "Не удалось открыть старый порт ${CURRENT_SSH_PORT}"; exit 1; }
    warn "Временно открыт старый порт ${CURRENT_SSH_PORT}."
fi

FINAL_UFW_SSH_PORT="${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}"
ufw allow "${FINAL_UFW_SSH_PORT}"/tcp comment 'SSH' \
    || { err "Не удалось открыть SSH-порт ${FINAL_UFW_SSH_PORT}"; exit 1; }

ufw allow 80/tcp  comment 'HTTP'      || { err "ufw allow 80 упал";  exit 1; }
ufw allow 443/tcp comment 'HTTPS'     || { err "ufw allow 443/tcp упал"; exit 1; }
ufw allow 443/udp comment 'QUIC/Hysteria2' || { err "ufw allow 443/udp упал"; exit 1; }

# Проверяем, что правило для SSH реально появилось.
if ! ufw_has_rule "${FINAL_UFW_SSH_PORT}"; then
    err "UFW не содержит правила для порта ${FINAL_UFW_SSH_PORT}. Прерываем."
    echo "--- ufw show added ---"
    ufw show added 2>/dev/null || true
    echo "--- ufw status verbose ---"
    ufw status verbose || true
    exit 1
fi

info "Правила подготовлены. Включение — в самом конце."
step_done

# ============================================================
#  7. Fail2Ban
# ============================================================
step_start "Fail2Ban"
backup_file /etc/fail2ban/jail.local

F2B_PORT="${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime            = 1h
bantime.increment  = true
bantime.factor     = 2
bantime.maxtime    = 1w
findtime           = 10m
maxretry           = 3
backend            = systemd
banaction          = ufw
banaction_allports = ufw
ignoreip           = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${F2B_PORT}
filter   = sshd
maxretry = 3
bantime  = 24h

[sshd-ddos]
enabled  = true
port     = ${F2B_PORT}
filter   = sshd-ddos
maxretry = 6
bantime  = 1w
EOF

systemctl enable fail2ban
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd 2>/dev/null || warn "fail2ban ещё не видит sshd (норма, если лог пуст)"
step_done

# ============================================================
#  8. Sysctl hardening
# ============================================================
step_start "Sysctl hardening"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
vm.swappiness = 10
EOF
sysctl --system >/dev/null
log "Sysctl применён"
step_done

# ============================================================
#  9. Автообновления
# ============================================================
step_start "unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades
systemctl restart unattended-upgrades

if confirm "Автоматическая перезагрузка после обновлений ядра (04:00)?"; then
    cat > /etc/apt/apt.conf.d/51unattended-upgrades-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
    log "Авторебут включён."
else
    log "Авторебут отключён."
fi
step_done

# ============================================================
#  10. Финальные проверки
# ============================================================
step_start "Финальные проверки"
chmod 700 /root
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
rkhunter --update   --nocolors >/dev/null 2>&1 || true
rkhunter --propupd  --nocolors >/dev/null 2>&1 || true
log "rkhunter обновлён."

SANITY_PORT="${ACTUAL_SSH_PORT:-${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}}"
if ! port_is_listening "$SANITY_PORT"; then
    warn "sshd не слушает ожидаемый порт ${SANITY_PORT}. Проверьте sshd -T и systemctl status ssh.socket."
fi
if ! ufw_has_rule "${SANITY_PORT}"; then
    warn "UFW не содержит правила для ${SANITY_PORT}/tcp. Добавьте: ufw allow ${SANITY_PORT}/tcp"
fi

step_done

# ============================================================
#  ИТОГОВАЯ СВОДКА
# ============================================================
PUBLIC_IP="$(get_public_ip)"
FINAL_PORT="${ACTUAL_SSH_PORT:-${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}}"
FINAL_USER="${NEW_USER:-root}"
FINAL_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}           НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА!                     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}📋 ИТОГ:${NC}"
echo -e "  • IP (IPv4):               ${GREEN}${PUBLIC_IP}${NC}"
echo -e "  • SSH-порт:                ${RED}${FINAL_PORT}${NC}"
echo -e "  • Пользователь:            ${GREEN}${FINAL_USER}${NC}"
echo -e "  • PermitRootLogin:         ${RED}${ACTUAL_PERMIT_ROOT_LOGIN:-${ROOT_LOGIN_VAL}}${NC}"
echo -e "  • PasswordAuthentication:  ${RED}${ACTUAL_PASSWORD_AUTH:-${FINAL_PASSWORD_AUTH}}${NC}"
echo -e "  • Часовой пояс:            ${GREEN}${FINAL_TZ}${NC}"
echo -e "  • Лог:                     ${LOG_FILE}"

[ -f /root/GENERATED_PRIVATE_KEY.txt ] && \
    echo -e "  • Приватный ключ:          ${RED}/root/GENERATED_PRIVATE_KEY.txt${NC}"
[ -n "$NEW_SSH_PORT" ] && \
    echo -e "  • Порт сохранён в:         /root/.new_ssh_port"
if [ -n "$NEW_USER" ] && [ -f "/etc/sudoers.d/90-${NEW_USER}" ]; then
    echo -e "  • Sudo для ${NEW_USER}:     ${YELLOW}NOPASSWD${NC} (см. /etc/sudoers.d/90-${NEW_USER})"
fi

SCRIPT_END=$(date +%s)
TOTAL_ELAPSED=$((SCRIPT_END - SCRIPT_START))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))
echo -e "  • Общее время выполнения:  ${GREEN}${TOTAL_MIN} мин ${TOTAL_SEC} сек${NC}"

echo ""
echo -e "${YELLOW}🔗 Подключение:${NC}"
echo -e "  ${GREEN}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
echo ""
echo -e "${YELLOW}📋 UFW будет применён:${NC}"
echo "--- ufw show added ---"
ufw show added 2>/dev/null || true
echo ""
echo "--- ufw status verbose ---"
ufw status verbose || true
echo ""

if ! confirm "Применить UFW и перезапустить SSH?"; then
    warn "Отменено. UFW выключен. Включить вручную: ufw enable"
    warn "Перезапуск SSH: systemctl restart ssh"
    exit 0
fi

# ============================================================
#  11. Применение
# ============================================================
log "Применение UFW..."
ufw --force enable || { err "ufw enable упал"; exit 1; }
log "UFW включён."

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}⚠️  СЕЙЧАС ПЕРЕЗАПУСК SSH. Откройте НОВОЕ окно и проверьте.  ${NC}"
echo -e "${RED}    НЕ закрывайте эту сессию до успешного входа.             ${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

PORTS_BEFORE_RESTART="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | tr '\n' ' ')"

if service_restart_or_reload_ssh; then
    echo -e "${GREEN}✅ SSH перезапущен.${NC}"

    sleep 2

    PORTS_AFTER_RESTART="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | tr '\n' ' ')"
    echo -e "  Слушаемые SSH-порты до рестарта:    ${PORTS_BEFORE_RESTART:-нет}"
    echo -e "  Слушаемые SSH-порты после рестарта: ${PORTS_AFTER_RESTART:-нет}"

    CHECK_PORT="${NEW_SSH_PORT:-${FINAL_PORT}}"
    if ! port_is_listening "$CHECK_PORT"; then
        err "sshd НЕ слушает порт ${CHECK_PORT} после рестарта!"
        err "Диагностика:"
        err "  sshd -T | grep -i '^port'"
        err "  systemctl status ssh.socket ssh.service 2>/dev/null"
        err "  journalctl -u ssh -u sshd --since '2 min ago' -n 50"
        err "Старый порт в UFW НЕ будет закрыт. Перезагрузка отменена."
        exec 1>&3 2>&1
        wait 2>/dev/null || true
        exit 1
    fi
    log "sshd слушает порт ${CHECK_PORT} — OK."
else
    echo -e "${RED}❌ SSH не перезапущен. Проверьте: sshd -t; systemctl status ssh${NC}"
    warn "Старый порт в UFW НЕ будет закрыт."
    exec 1>&3 2>&1
    wait 2>/dev/null || true
    exit 1
fi
echo ""

# ============================================================
#  12. Закрытие старого порта
# ============================================================
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    if ! port_is_listening "$NEW_SSH_PORT"; then
        warn "Порт ${NEW_SSH_PORT} не слушается — старый порт НЕ закрываем."
    else
        echo -e "${YELLOW}🔐 Старый порт ${CURRENT_SSH_PORT} открыт временно.${NC}"
        if confirm "Проверили вход через новый порт ${FINAL_PORT}?"; then
            RULE_NUM="$(ufw status numbered 2>/dev/null \
                | awk -v p="${CURRENT_SSH_PORT}/tcp" \
                    '/\]/ && $0 ~ p {gsub(/[^0-9]/,"",$1); print $1; exit}')"
            if [ -n "$RULE_NUM" ]; then
                yes | ufw delete "$RULE_NUM" >/dev/null 2>&1 \
                    && log "Старый порт ${CURRENT_SSH_PORT} закрыт (правило #${RULE_NUM})." \
                    || warn "Не удалось удалить правило #${RULE_NUM}. Закройте вручную: ufw delete allow ${CURRENT_SSH_PORT}/tcp"
            else
                ufw delete allow "${CURRENT_SSH_PORT}"/tcp >/dev/null 2>&1 \
                    || ufw delete limit "${CURRENT_SSH_PORT}"/tcp >/dev/null 2>&1 \
                    || warn "Правило для старого порта не найдено."
                log "Старый порт ${CURRENT_SSH_PORT} закрыт (фолбэк)."
            fi
            echo -e "✅ Доступен только ${FINAL_PORT}."
        else
            warn "Закрыть позже: ufw delete allow ${CURRENT_SSH_PORT}/tcp"
        fi
    fi
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}           ГОТОВО!                                          ${NC}"
echo -e "${GREEN}============================================================${NC}"

if [ -f /root/GENERATED_PRIVATE_KEY.txt ]; then
    echo -e "${YELLOW}⚠️  Удалите приватный ключ:${NC}"
    echo -e "   ${RED}rm -f /root/GENERATED_PRIVATE_KEY.txt${NC}"
fi
echo -e "${GREEN}Спасибо!${NC}"

# ============================================================
#  Опциональная перезагрузка сервера.
# ============================================================
echo ""
if ! port_is_listening "${FINAL_PORT}"; then
    err "Отмена перезагрузки: sshd не слушает ${FINAL_PORT}."
    err "Сначала исправьте: sshd -t; systemctl restart ssh; ss -tlnp | grep sshd"
elif confirm "Перезагрузить сервер сейчас? (рекомендуется для применения всех изменений)"; then
    warn "Перезагрузка через 1 минуту. Отменить: shutdown -c"
    echo -e "  Команда отмены: ${GREEN}shutdown -c${NC}"
    echo ""
    shutdown -r +1 "Server hardening завершён. Плановая перезагрузка."
    echo -e "Сервер уйдёт на перезагрузку через 1 минуту."
    echo -e "После перезагрузки подключение: ${YELLOW}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
else
    warn "Перезагрузка отложена. Рекомендуется выполнить вручную:"
    echo -e "  ${GREEN}sudo reboot${NC}"
fi
echo ""

exec 1>&3 2>&1
wait 2>/dev/null || true