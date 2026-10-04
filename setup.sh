#!/bin/bash
# ============================================================
#  Скрипт базовой настройки и hardening Linux-сервера
#  Поддержка: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Запуск: строго от имени root
#  Репозиторий: https://github.com/thealekseev/vps-setup
# ============================================================

# Строгий режим: необъявленные переменные и ошибки в конвейерах прерывают выполнение
set -uo pipefail

# ---------- Цвета для вывода ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   NC='\033[0m'

# ---------- Логирование ----------
LOG_FILE="/var/log/server-hardening.log"

# Сохраняем оригинальные дескрипторы stdout/stderr в FD 3 и 4.
# Это критически важно для корректного завершения процесса tee и предотвращения 
# deadlock при последующем вызове команды wait.
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# Глобальный обработчик ошибок: выводит номер строки и инструкцию по восстановлению,
# чтобы скрипт не завершался молча при непредвиденных сбоях.
trap 'err "Непредвиденная ошибка в строке $LINENO. Лог: $LOG_FILE. Соединение НЕ перезапущено. Проверьте: sshd -t"' ERR

# ---------- Управление шагами ----------
STEP=0; TOTAL_STEPS=10; START_TIME=0

step_start() {
    # Используем арифметическое присваивание, чтобы избежать возврата exit code 1 
    # при STEP=0 (что в режиме set -e ложно спровоцировало бы срабатывание trap ERR).
    STEP=$((STEP + 1))
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  [$STEP/$TOTAL_STEPS] $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    START_TIME=$(date +%s)
}

run_timed() {
    local desc="$1"; shift
    echo -e "  ${CYAN}↳${NC} $desc"
    "$@"
}

step_done() {
    local END_TIME; END_TIME=$(date +%s)
    echo -e "${GREEN}  [OK] Выполнено за $((END_TIME - START_TIME)) сек.${NC}"
}

# ---------- Вспомогательные функции ----------
confirm() {
    local prompt="$1" answer
    # Чтение строго из /dev/tty гарантирует работу интерактивных запросов 
    # даже при запуске скрипта через конвейер (например, curl ... | sudo bash).
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer < /dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
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

service_restart_or_reload_ssh() {
    local unit
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
        unit="ssh"
    elif systemctl list-unit-files | grep -q '^sshd\.service'; then
        unit="sshd"
    else
        err "Не найден сервис ssh/sshd"; return 1
    fi
    
    # Проверяем синтаксис конфигурации перед любым действием с сервисом
    sshd -t || { err "sshd -t не проходит. Перезапуск отменён."; return 1; }
    
    if systemctl reload "$unit" 2>/dev/null; then
        log "SSH перезагружен (reload, $unit)"; return 0
    fi
    
    err "reload не удался, пробуем restart..."
    systemctl restart "$unit" && { log "SSH перезапущен (restart, $unit)"; return 0; }
    err "Не удалось перезапустить SSH!"; return 1
}

get_public_ip() {
    # Принудительно запрашиваем IPv4 (-4), чтобы избежать выдачи IPv6-адреса, 
    # к которому у пользователя может не быть доступа через домашнего провайдера.
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

# Определяем способ активации SSH. В новых версиях Ubuntu/Debian используется ssh.socket,
# который игнорирует параметр Port в sshd_config. Запоминаем это для последующей коррекции.
SSH_USES_SOCKET=0
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    SSH_USES_SOCKET=1
    warn "Обнаружена socket-activation (ssh.socket). Будет отключена при смене порта."
fi

# ============================================================
#  1. Обновление системы
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
#  2. Установка утилит
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

# Жёсткая проверка наличия критически важных бинарных файлов.
# Если их нет, дальнейшее выполнение бессмысленно и опасно.
command -v ufw            >/dev/null || { err "ufw не установлен, дальше нельзя"; exit 1; }
command -v fail2ban-server >/dev/null || { err "fail2ban-server не установлен, дальше нельзя"; exit 1; }
step_done

# ============================================================
#  3. Swap и время
# ============================================================
step_start "Swap и время"
# Портативная проверка наличия активного swap (работает на всех версиях util-linux)
if ! swapon --show 2>/dev/null | grep -q .; then
    warn "Swap не найден. Создаём файл подкачки 2GB..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 2GB создан."
else
    info "Swap уже настроен."
fi

timedatectl set-timezone "${TZ:-UTC}" 2>/dev/null || warn "timedatectl недоступен"
systemctl enable --now chrony 2>/dev/null \
  || systemctl enable --now systemd-timesyncd 2>/dev/null || true
step_done

# ============================================================
#  4. SSH hardening
# ============================================================
step_start "SSH hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$SSHD_DIR"
HARDENING_CONF="${SSHD_DIR}/99-hardening.conf"
backup_file "$SSHD_CONFIG"

# --- 4.1. Создание non-root пользователя ---
NEW_USER=""
if confirm "Создать non-root пользователя с правами sudo?"; then
    while true; do
        read -r -p "$(echo -e "${YELLOW}Имя пользователя: ${NC}")" NEW_USER < /dev/tty
        [ -z "$NEW_USER" ] && { warn "Пустое имя."; continue; }
        validate_username "$NEW_USER" || { warn "Недопустимое имя."; continue; }
        break
    done

    USER_JUST_CREATED=0
    if id "$NEW_USER" &>/dev/null; then
        info "Пользователь $NEW_USER уже существует."
    else
        adduser --disabled-password --gecos "" "$NEW_USER"
        USER_JUST_CREATED=1
        log "Пользователь $NEW_USER создан."
    fi

    # Добавляем в группу sudo безусловно, даже если пользователь уже существовал
    usermod -aG sudo "$NEW_USER"
    log "Пользователь $NEW_USER добавлен в группу sudo."

    # Создаём drop-in файл для sudo без пароля, так как adduser --disabled-password 
    # устанавливает заблокированный пароль ("!"), что ломает работу sudo.
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

    # Копируем ключи root новому пользователю для удобства первоначального входа
    if [ -s /root/.ssh/authorized_keys ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
        install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
        install -m 600 -o "$NEW_USER" -g "$NEW_USER" \
            /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
        log "SSH-ключи root скопированы пользователю $NEW_USER."
    fi
fi

# --- 4.2. Управление SSH-ключами ---
HAS_KEYS=0
[ -s /root/.ssh/authorized_keys ] && HAS_KEYS=1
for d in /home/*/.ssh; do
    [ -d "$d" ] && [ -s "$d/authorized_keys" ] && { HAS_KEYS=1; break; }
done

DISABLE_PASSWORD="no"
if [ "$HAS_KEYS" -eq 1 ]; then
    confirm "Найдены существующие SSH-ключи. Отключить вход по паролю?" && DISABLE_PASSWORD="yes"
else
    warn "SSH-ключи не найдены!"
    if confirm "Сгенерировать новый ed25519-ключ?"; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        
        # Генерируем ключ только если его нет, и перенаправляем ввод из /dev/null, 
        # чтобы избежать зависания при отсутствии TTY.
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

# --- 4.3. Смена порта SSH ---
NEW_SSH_PORT=""
if confirm "Сменить стандартный SSH-порт (22)?"; then
    for _ in $(seq 1 20); do
        C=$(shuf -i 10000-60000 -n 1)
        if ! ss -tln | grep -q ":${C} "; then NEW_SSH_PORT="$C"; break; fi
    done
    [ -z "$NEW_SSH_PORT" ] && { err "Не удалось найти свободный порт."; exit 1; }
    
    echo "$NEW_SSH_PORT" > /root/.new_ssh_port; chmod 600 /root/.new_ssh_port
    log "Новый SSH-порт: $NEW_SSH_PORT"

    # Отключаем ssh.socket, иначе параметр Port в sshd_config будет проигнорирован
    if [ "$SSH_USES_SOCKET" -eq 1 ]; then
        log "Отключаем ssh.socket..."
        systemctl disable --now ssh.socket 2>/dev/null || warn "disable ssh.socket не удался"
        systemctl enable ssh.service 2>/dev/null || true
        systemctl start ssh.service 2>/dev/null || true
    fi
fi

# --- 4.4. Формирование конфигурации SSH ---
# Собираем массив пользователей, у которых реально есть настроенные ключи
declare -a KEYED_USERS=()
[ -s /root/.ssh/authorized_keys ] && KEYED_USERS+=("root")
[ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ] \
    && KEYED_USERS+=("$NEW_USER")

# КРИТИЧЕСКАЯ ЗАЩИТА: Если ни у кого нет ключей, отключать пароль нельзя!
if [ ${#KEYED_USERS[@]} -eq 0 ] && [ "$DISABLE_PASSWORD" = "yes" ]; then
    warn "КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: Ни у одного пользователя нет ключей."
    warn "Вход по паролю принудительно оставлен включенным во избежание блокировки."
    DISABLE_PASSWORD="no"
fi

# Запрет прямого входа root разрешен только если у нового пользователя есть ключи
if [ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
    ROOT_LOGIN_VAL="no"
else
    ROOT_LOGIN_VAL="prohibit-password"
fi

cat > "$HARDENING_CONF" <<EOF
# Сгенерировано hardening-скриптом $(date -Iseconds)

# Аутентификация
PermitRootLogin ${ROOT_LOGIN_VAL}
PasswordAuthentication ${DISABLE_PASSWORD}
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

if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$SSHD_CONFIG"; then
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSHD_CONFIG"
fi

# Права доступа:
# sshd_config — 644 (стандарт дистрибутива, ожидается инструментами аудита)
# 99-hardening.conf — 600 (drop-in с эффективной политикой, CIS §5.2.1)
# Явно фиксируем владельца root:root, так как chmod владельца не устанавливает.
chown root:root "$SSHD_CONFIG" "$HARDENING_CONF"
chmod 644 "$SSHD_CONFIG"
chmod 600 "$HARDENING_CONF"

if ! sshd -t; then
    err "sshd -t не проходит. Откат hardening-конфига."
    rm -f "$HARDENING_CONF"
    exit 1
fi
log "sshd -t OK"
step_done

# ============================================================
#  5. UFW — подготовка правил без включения
# ============================================================
step_start "Подготовка правил UFW"

sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw

# Предупреждаем, если UFW уже активен: --force reset уничтожит существующие правила.
if ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "UFW уже активен — команда reset удалит все текущие правила."
    if ! confirm "Сбросить существующие правила UFW и начать заново?"; then
        err "Отменено. Прервите выполнение и настройте UFW вручную."
        exit 1
    fi
fi

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

CURRENT_SSH_PORT=""
if [ -n "${SSH_CONNECTION:-}" ]; then
    CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
fi

# Совместимый fallback: разбираем established-соединения через ss, 
# избегая фильтров sport=:22, которые работают неверно на некоторых версиях.
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=$(ss -tn state established 2>/dev/null \
        | awk '{print $4}' \
        | grep -E ':[0-9]+$' \
        | head -n 1 \
        | cut -d: -f2)
fi
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
log "Текущий SSH-порт сессии: ${CURRENT_SSH_PORT}"

# Сохраняем текущую сессию, открывая старый порт, если он отличается от нового
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    ufw limit "${CURRENT_SSH_PORT}"/tcp comment 'SSH OLD (temp)'
    warn "Временно открыт старый порт ${CURRENT_SSH_PORT}."
fi

# Открываем реальный порт сессии, чтобы избежать lockout на нестандартных портах
if [ -n "$NEW_SSH_PORT" ]; then
    ufw limit "${NEW_SSH_PORT}"/tcp comment 'SSH (limited)'
else
    ufw limit "${CURRENT_SSH_PORT:-22}"/tcp comment 'SSH (limited)'
fi

ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'QUIC/Hysteria2'
info "Правила подготовлены. Включение — в самом конце."
step_done

# ============================================================
#  6. Fail2Ban
# ============================================================
step_start "Fail2Ban"
backup_file /etc/fail2ban/jail.local

# Если порт не менялся, jail должен слушать реальный порт сессии, а не 22
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
#  7. Sysctl hardening
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
#  8. Автообновления
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
#  9. Финальные проверки
# ============================================================
step_start "Финальные проверки"
chmod 700 /root
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
rkhunter --update   --nocolors >/dev/null 2>&1 || true
rkhunter --propupd  --nocolors >/dev/null 2>&1 || true
log "rkhunter обновлён."
step_done

# ============================================================
#  ИТОГОВАЯ СВОДКА
# ============================================================
PUBLIC_IP="$(get_public_ip)"
FINAL_PORT="${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}"
FINAL_USER="${NEW_USER:-root}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}           НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА!                     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}📋 ИТОГ:${NC}"
echo -e "  • IP (IPv4):               ${GREEN}${PUBLIC_IP}${NC}"
echo -e "  • SSH-порт:                ${RED}${FINAL_PORT}${NC}"
echo -e "  • Пользователь:            ${GREEN}${FINAL_USER}${NC}"
echo -e "  • Root login:              ${RED}${ROOT_LOGIN_VAL}${NC}"
echo -e "  • Password auth:           ${RED}${DISABLE_PASSWORD}${NC}"
echo -e "  • Лог:                     ${LOG_FILE}"

[ -f /root/GENERATED_PRIVATE_KEY.txt ] && \
    echo -e "  • Приватный ключ:          ${RED}/root/GENERATED_PRIVATE_KEY.txt${NC}"
[ -n "$NEW_SSH_PORT" ] && \
    echo -e "  • Порт сохранён в:         /root/.new_ssh_port"
if [ -n "$NEW_USER" ] && [ -f "/etc/sudoers.d/90-${NEW_USER}" ]; then
    echo -e "  • Sudo для ${NEW_USER}:     ${YELLOW}NOPASSWD${NC} (см. /etc/sudoers.d/90-${NEW_USER})"
fi

echo ""
echo -e "${YELLOW}🔗 Подключение:${NC}"
echo -e "  ${GREEN}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
echo ""
echo -e "${YELLOW}📋 UFW будет применён:${NC}"
ufw status verbose
echo ""

if ! confirm "Применить UFW и перезапустить SSH?"; then
    warn "Отменено. UFW выключен. Включить вручную: ufw enable"
    warn "Перезапуск SSH: systemctl reload ssh"
    exit 0
fi

# ============================================================
#  10. Применение
# ============================================================
log "Применение UFW..."
ufw --force enable
log "UFW включён."

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}⚠️  СЕЙЧАС ПЕРЕЗАПУСК SSH. Откройте НОВОЕ окно и проверьте.  ${NC}"
echo -e "${RED}    НЕ закрывайте эту сессию до успешного входа.             ${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

if service_restart_or_reload_ssh; then
    echo -e "${GREEN}✅ SSH перезапущен.${NC}"
else
    echo -e "${RED}❌ SSH не перезапущен. Проверьте: sshd -t; systemctl status ssh${NC}"
fi
echo ""

# ============================================================
#  11. Закрытие старого порта
# ============================================================
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    echo -e "${YELLOW}🔐 Старый порт ${CURRENT_SSH_PORT} открыт временно.${NC}"
    if confirm "Проверили вход через новый порт ${FINAL_PORT}?"; then
        ufw delete limit "${CURRENT_SSH_PORT}"/tcp >/dev/null 2>&1
        log "Старый порт ${CURRENT_SSH_PORT} закрыт."
        echo -e "${GREEN}✅ Доступен только ${FINAL_PORT}.${NC}"
    else
        warn "Закрыть позже: ufw delete limit ${CURRENT_SSH_PORT}/tcp"
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
# Корректное завершение логирования.
# Закрываем pipe → tee получает EOF → wait дожидается завершения tee.
# Без этого шага команда wait вызывала бы вечный deadlock.
# ============================================================
exec 1>&3 2>&1
wait 2>/dev/null || true