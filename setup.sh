#!/bin/bash
# ============================================================
#  Скрипт базовой настройки и hardening Linux-сервера
#  Поддержка: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Запуск: строго от имени root
#  Репозиторий: https://github.com/thealekseev/vps-setup
# ============================================================

set -uo pipefail

# ---------- Цвета для вывода ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   NC='\033[0m'

# ---------- Логирование ----------
LOG_FILE="/var/log/server-hardening.log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

trap 'err "Непредвиденная ошибка в строке $LINENO. Лог: $LOG_FILE. Соединение НЕ перезапущено. Проверьте: sshd -t"' ERR

# ---------- Управление шагами и СТАТУС-БАР ----------
STEP=0; TOTAL_STEPS=10; START_TIME=0

step_start() {
    STEP=$((STEP + 1))
    local progress=$((STEP * 100 / TOTAL_STEPS))
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  ШАГ [$STEP/$TOTAL_STEPS] (${progress}%) : $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    START_TIME=$(date +%s)
}

# Функция с живым спиннером, чтобы пользователь видел, что скрипт не завис
run_timed() {
    local desc="$1"
    shift
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' # Unicode-спиннер (выглядит как плавная анимация)
    local i=0
    
    echo -en "  ${CYAN}⟳${NC} $desc "
    
    # Запускаем спиннер в фоновом процессе
    (
        while true; do
            printf "\b%s" "${spinstr:i++%10:1}"
            sleep 0.1
        done
    ) &
    local spinner_pid=$!
    
    # Выполняем команду. Её вывод будет естественным образом сдвигать спиннер, 
    # что также является отличным индикатором "живости" процесса.
    "$@"
    local status=$?
    
    # Останавливаем спиннер
    kill $spinner_pid 2>/dev/null
    wait $spinner_pid 2>/dev/null
    
    # Очищаем строку и выводим финальный статус
    printf "\r\033[K"
    if [ $status -eq 0 ]; then
        echo -e "  ${GREEN}✅${NC} $desc"
    else
        echo -e "  ${RED}❌${NC} $desc (код: $status)"
    fi
    return $status
}

step_done() {
    local END_TIME; END_TIME=$(date +%s)
    echo -e "${GREEN}  ⏱  Выполнено за $((END_TIME - START_TIME)) сек.${NC}"
}

# ---------- Вспомогательные функции ----------
confirm() {
    local prompt="$1" answer
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
    
    sshd -t || { err "sshd -t не проходит. Перезапуск отменён."; return 1; }
    
    if systemctl reload "$unit" 2>/dev/null; then
        log "SSH перезагружен (reload, $unit)"; return 0
    fi
    
    err "reload не удался, пробуем restart..."
    systemctl restart "$unit" && { log "SSH перезапущен (restart, $unit)"; return 0; }
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

echo -e "${YELLOW}⟳ Проверка блокировки dpkg...${NC}"
wait_count=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    wait_count=$((wait_count + 1))
    # Визуальный "пульс": печатаем точку каждые 10 секунд, чтобы показать, что скрипт жив
    if [ $((wait_count % 10)) -eq 0 ]; then
        echo -n "."
    fi
    sleep 1
done
echo "" # Переход на новую строку после ожидания
log "Пакетный менеджер свободен."

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
    err "Установка пакетов провалилась."
    confirm "Продолжить?" || exit 1
fi

command -v ufw            >/dev/null || { err "ufw не установлен"; exit 1; }
command -v fail2ban-server >/dev/null || { err "fail2ban-server не установлен"; exit 1; }
step_done

# ============================================================
#  3. Swap и время
# ============================================================
step_start "Swap и время"
if ! swapon --show 2>/dev/null | grep -q .; then
    run_timed "Создание Swap 2GB" bash -c 'fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile; grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab'
    log "Swap 2GB создан."
else
    info "Swap уже настроен."
fi

run_timed "Настройка времени" bash -c 'timedatectl set-timezone "${TZ:-UTC}" 2>/dev/null || true; systemctl enable --now chrony 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true'
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
        run_timed "Создание пользователя" adduser --disabled-password --gecos "" "$NEW_USER"
        USER_JUST_CREATED=1
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
        fi
    fi

    if [ -s /root/.ssh/authorized_keys ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
        install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
        install -m 600 -o "$NEW_USER" -g "$NEW_USER" /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
        log "SSH-ключи root скопированы пользователю $NEW_USER."
    fi
fi

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
        if [ ! -f /root/.ssh/id_ed25519 ]; then
            run_timed "Генерация ключа" bash -c 'ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "root@$(hostname)" </dev/null >/dev/null 2>&1'
        else
            info "Ключ уже существует."
        fi
        cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        
        KEY_FILE="/root/GENERATED_PRIVATE_KEY.txt"
        cp /root/.ssh/id_ed25519 "$KEY_FILE"; chmod 400 "$KEY_FILE"
        echo -e "\n${RED}===========================================================${NC}"
        echo -e "${RED}  Приватный ключ: ${KEY_FILE}${NC}"
        echo -e "${RED}  СКОПИРУЙТЕ его и удалите файл после настройки!${NC}"
        echo -e "${RED}===========================================================${NC}\n"
        
        if confirm "Вы скопировали ключ и готовы отключить пароль?"; then
            DISABLE_PASSWORD="yes"
            if [ -n "$NEW_USER" ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
                install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
                install -m 600 -o "$NEW_USER" -g "$NEW_USER" /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
            fi
        else
            warn "Вход по паролю оставлен включенным."
        fi
    fi
fi

NEW_SSH_PORT=""
if confirm "Сменить стандартный SSH-порт (22)?"; then
    for _ in $(seq 1 20); do
        C=$(shuf -i 10000-60000 -n 1)
        if ! ss -tln | grep -q ":${C} "; then NEW_SSH_PORT="$C"; break; fi
    done
    [ -z "$NEW_SSH_PORT" ] && { err "Не удалось найти свободный порт."; exit 1; }
    
    echo "$NEW_SSH_PORT" > /root/.new_ssh_port; chmod 600 /root/.new_ssh_port
    log "Новый SSH-порт: $NEW_SSH_PORT"

    if [ "$SSH_USES_SOCKET" -eq 1 ]; then
        run_timed "Отключение ssh.socket" bash -c 'systemctl disable --now ssh.socket 2>/dev/null || true; systemctl enable --now ssh.service 2>/dev/null || true'
    fi
fi

declare -a KEYED_USERS=()
[ -s /root/.ssh/authorized_keys ] && KEYED_USERS+=("root")
[ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ] && KEYED_USERS+=("$NEW_USER")

if [ ${#KEYED_USERS[@]} -eq 0 ] && [ "$DISABLE_PASSWORD" = "yes" ]; then
    warn "КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: Ни у одного пользователя нет ключей."
    warn "Вход по паролю принудительно оставлен включенным."
    DISABLE_PASSWORD="no"
fi

if [ -n "$NEW_USER" ] && [ -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
    ROOT_LOGIN_VAL="no"
else
    ROOT_LOGIN_VAL="prohibit-password"
fi

cat > "$HARDENING_CONF" <<EOF
# Сгенерировано hardening-скриптом $(date -Iseconds)
PermitRootLogin ${ROOT_LOGIN_VAL}
PasswordAuthentication ${DISABLE_PASSWORD}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
MaxStartups 10:30:60
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
#  5. UFW
# ============================================================
step_start "Подготовка правил UFW"

sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw

if ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "UFW уже активен — команда reset удалит все текущие правила."
    if ! confirm "Сбросить существующие правила UFW и начать заново?"; then
        err "Отменено."; exit 1
    fi
fi

run_timed "Сброс UFW" ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

CURRENT_SSH_PORT=""
if [ -n "${SSH_CONNECTION:-}" ]; then
    CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
fi
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=$(ss -tn state established 2>/dev/null | awk '{print $4}' | grep -E ':[0-9]+$' | head -n 1 | cut -d: -f2)
fi
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
log "Текущий SSH-порт сессии: ${CURRENT_SSH_PORT}"

if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    run_timed "Открытие старого порта (временно)" ufw limit "${CURRENT_SSH_PORT}"/tcp comment 'SSH OLD (temp)'
fi

if [ -n "$NEW_SSH_PORT" ]; then
    run_timed "Открытие нового SSH-порта" ufw limit "${NEW_SSH_PORT}"/tcp comment 'SSH (limited)'
else
    run_timed "Открытие SSH-порта" ufw limit "${CURRENT_SSH_PORT:-22}"/tcp comment 'SSH (limited)'
fi

run_timed "Открытие HTTP/HTTPS" bash -c 'ufw allow 80/tcp comment "HTTP"; ufw allow 443/tcp comment "HTTPS"; ufw allow 443/udp comment "QUIC"'
info "Правила подготовлены."
step_done

# ============================================================
#  6. Fail2Ban
# ============================================================
step_start "Fail2Ban"
backup_file /etc/fail2ban/jail.local

F2B_PORT="${NEW_SSH_PORT:-${CURRENT_SSH_PORT:-22}}"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h; bantime.increment = true; bantime.factor = 2; bantime.maxtime = 1w
findtime = 10m; maxretry = 3; backend = systemd; banaction = ufw; ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true; port = ${F2B_PORT}; filter = sshd; maxretry = 3; bantime = 24h

[sshd-ddos]
enabled = true; port = ${F2B_PORT}; filter = sshd-ddos; maxretry = 6; bantime = 1w
EOF

run_timed "Перезапуск Fail2Ban" bash -c 'systemctl enable --now fail2ban; sleep 2'
fail2ban-client status sshd 2>/dev/null || warn "fail2ban ещё не видит sshd (норма)"
step_done

# ============================================================
#  7. Sysctl
# ============================================================
step_start "Sysctl hardening"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1; net.ipv4.conf.default.rp_filter = 1; net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0; net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0; net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0; net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0; net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0; net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1; net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.dmesg_restrict = 1; kernel.kptr_restrict = 2; kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1; fs.protected_symlinks = 1; fs.suid_dumpable = 0; vm.swappiness = 10
EOF
run_timed "Применение sysctl" sysctl --system >/dev/null
step_done

# ============================================================
#  8. Автообновления
# ============================================================
step_start "unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1"; APT::Periodic::Unattended-Upgrade "1"; APT::Periodic::AutocleanInterval "7";
EOF
run_timed "Включение автообновлений" bash -c 'systemctl enable --now unattended-upgrades'

if confirm "Автоматическая перезагрузка после обновлений ядра (04:00)?"; then
    cat > /etc/apt/apt.conf.d/51unattended-upgrades-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true"; Unattended-Upgrade::Automatic-Reboot-WithUsers "false"; Unattended-Upgrade::Automatic-Reboot-Time "04:00";
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
chmod 700 /root; chmod 700 /root/.ssh 2>/dev/null || true; chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
run_timed "Обновление rkhunter" bash -c 'rkhunter --update --nocolors >/dev/null 2>&1 || true; rkhunter --propupd --nocolors >/dev/null 2>&1 || true'
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
echo -e "${YELLOW}📋 ИТОГ:${NC}"
echo -e "  • IP (IPv4):               ${GREEN}${PUBLIC_IP}${NC}"
echo -e "  • SSH-порт:                ${RED}${FINAL_PORT}${NC}"
echo -e "  • Пользователь:            ${GREEN}${FINAL_USER}${NC}"
echo -e "  • Root login:              ${RED}${ROOT_LOGIN_VAL}${NC}"
echo -e "  • Password auth:           ${RED}${DISABLE_PASSWORD}${NC}"
[ -f /root/GENERATED_PRIVATE_KEY.txt ] && echo -e "  • Приватный ключ:          ${RED}/root/GENERATED_PRIVATE_KEY.txt${NC}"
echo ""
echo -e "${YELLOW}🔗 Подключение:${NC}"
echo -e "  ${GREEN}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
echo ""
echo -e "${YELLOW}📋 UFW будет применён:${NC}"
ufw status verbose
echo ""

if ! confirm "Применить UFW и перезапустить SSH?"; then
    warn "Отменено. UFW выключен. Перезапуск SSH: systemctl reload ssh"
    exit 0
fi

log "Применение UFW..."
ufw --force enable
log "UFW включён."

echo -e "\n${RED}============================================================${NC}"
echo -e "${RED}⚠️  СЕЙЧАС ПЕРЕЗАПУСК SSH. Откройте НОВОЕ окно и проверьте.  ${NC}"
echo -e "${RED}    НЕ закрывайте эту сессию до успешного входа.             ${NC}"
echo -e "${RED}============================================================${NC}\n"

if service_restart_or_reload_ssh; then
    echo -e "${GREEN}✅ SSH перезапущен.${NC}"
else
    echo -e "${RED}❌ SSH не перезапущен. Проверьте: sshd -t; systemctl status ssh${NC}"
fi

if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    echo -e "\n${YELLOW}🔐 Старый порт ${CURRENT_SSH_PORT} открыт временно.${NC}"
    if confirm "Проверили вход через новый порт ${FINAL_PORT}?"; then
        run_timed "Закрытие старого порта" ufw delete limit "${CURRENT_SSH_PORT}"/tcp >/dev/null 2>&1
        echo -e "${GREEN}✅ Доступен только ${FINAL_PORT}.${NC}"
    else
        warn "Закрыть позже: ufw delete limit ${CURRENT_SSH_PORT}/tcp"
    fi
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}           ГОТОВО!                                          ${NC}"
echo -e "${GREEN}============================================================${NC}"
[ -f /root/GENERATED_PRIVATE_KEY.txt ] && echo -e "${YELLOW}⚠️  Удалите приватный ключ: ${RED}rm -f /root/GENERATED_PRIVATE_KEY.txt${NC}"
echo -e "${GREEN}Спасибо!${NC}"

exec 1>&3 2>&1
wait 2>/dev/null || true