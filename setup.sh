#!/bin/bash

# ============================================================
#  Скрипт базовой настройки и hardening Linux-сервера (v2.5)
#  Поддержка: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Запуск от имени root
#
#  Репозиторий: https://github.com/thealekseev/vps-setup
#
#  Изменения в v2.5:
#   - UFW больше НЕ включается в шаге 5 (правила только готовятся)
#   - Итоговая сводка + подтверждение → только ПОТОМ enable UFW
#   - Это защищает текущую SSH-сессию от обрыва на rkhunter --update
# ============================================================

set -uo pipefail

# ---------- Цвета ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- Логирование ----------
LOG_FILE="/var/log/server-hardening.log"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ---------- Вспомогательные функции ----------
confirm() {
    local prompt="$1"
    local answer
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer
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
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#name}" -gt 32 ] || [ -z "$name" ]; then
        return 1
    fi
    case "$name" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|sshd|ubuntu|debian)
            return 1
            ;;
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
        err "Не найден сервис ssh/sshd"
        return 1
    fi

    if ! sshd -t; then
        err "Конфигурация SSH некорректна. Перезапуск отменён."
        return 1
    fi

    systemctl reload "$unit" 2>/dev/null || systemctl restart "$unit"
    log "SSH перезапущен (${unit})"
}

get_public_ip() {
    curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
      || echo "unknown"
}

# ============================================================
#  0. Проверка прав, ОС и разблокировка пакетного менеджера
# ============================================================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Запустите скрипт от имени root (используйте sudo или войдите как root)"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    err "Не удалось определить ОС (/etc/os-release отсутствует)"
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"

case "$OS_ID" in
    ubuntu|debian) : ;;
    *)
        warn "ОС '$OS_ID' не тестировалась. Продолжить?"
        confirm "Продолжить на свой риск?" || exit 1
        ;;
esac

log "ОС: ${PRETTY_NAME:-$OS_ID $OS_VER}"
export DEBIAN_FRONTEND=noninteractive

log "Проверка блокировки пакетного менеджера..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "Пакетный менеджер заблокирован (возможно, работают фоновые обновления). Ждем 10 секунд..."
    sleep 10
done

# ============================================================
#  1. Обновление системы
# ============================================================
log "[1/9] Обновление пакетов и системы..."
apt-get update -y
apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
apt-get -y autoremove
apt-get -y autoclean

# ============================================================
#  2. Установка утилит
# ============================================================
log "[2/9] Установка базовых и защитных утилит..."
apt-get install -y \
    curl wget git unzip nano htop net-tools jq \
    ufw fail2ban \
    unattended-upgrades apt-listchanges needrestart \
    chrony auditd rkhunter

# ============================================================
#  2.5. Создание Swap-файла (если отсутствует)
# ============================================================
log "[2.5/9] Проверка и настройка Swap..."
if [ "$(swapon --show=SIZE | wc -l)" -le 1 ]; then
    warn "Swap не найден. Создаем файл подкачки 2GB для стабильности..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap-файл 2GB успешно создан и активирован."
else
    info "Swap уже настроен, пропускаем."
fi

# ============================================================
#  3. Часовой пояс и синхронизация времени
# ============================================================
log "[3/9] Настройка времени (UTC рекомендуется для логов)..."
timedatectl set-timezone "${TZ:-UTC}" 2>/dev/null || \
    warn "timedatectl недоступен, пропускаем (возможно, LXC контейнер)"

systemctl enable --now chrony 2>/dev/null || \
    systemctl enable --now systemd-timesyncd 2>/dev/null || true

# ============================================================
#  4. SSH-hardening
# ============================================================
log "[4/9] Настройка SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$SSHD_DIR"
HARDENING_CONF="${SSHD_DIR}/99-hardening.conf"

backup_file "$SSHD_CONFIG"

# --- 4.1. Non-root пользователь с sudo (С ВАЛИДАЦИЕЙ) ---
NEW_USER=""
if confirm "Создать non-root пользователя с правами sudo?"; then
    while true; do
        read -r -p "$(echo -e "${YELLOW}Введите имя нового пользователя (латиница, цифры, _ и -): ${NC}")" NEW_USER

        if [ -z "$NEW_USER" ]; then
            warn "Имя не может быть пустым. Попробуйте снова."
            continue
        fi

        if ! validate_username "$NEW_USER"; then
            warn "Недопустимое имя пользователя. Используйте только латинские буквы, цифры, _ и -. Имя должно начинаться с буквы или _."
            continue
        fi

        if id "$NEW_USER" &>/dev/null; then
            info "Пользователь $NEW_USER уже существует"
            break
        fi

        adduser --disabled-password --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        log "Пользователь $NEW_USER создан и добавлен в группу sudo"
        break
    done

    if [ -s /root/.ssh/authorized_keys ] && \
       [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
        install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
        install -m 600 -o "$NEW_USER" -g "$NEW_USER" \
            /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
        log "SSH-ключи root скопированы пользователю $NEW_USER"
    fi
fi

# --- 4.2. Проверка и интерактивная генерация SSH-ключей ---
HAS_KEYS=0
if [ -s /root/.ssh/authorized_keys ]; then HAS_KEYS=1; fi
for dir in /home/*/.ssh; do
    if [ -d "$dir" ] && [ -s "$dir/authorized_keys" ]; then
        HAS_KEYS=1
        break
    fi
done

DISABLE_PASSWORD="no"
if [ "$HAS_KEYS" -eq 1 ]; then
    if confirm "Найдены существующие SSH-ключи. Отключить вход по паролю?"; then
        DISABLE_PASSWORD="yes"
    fi
else
    warn "SSH-ключи не найдены! Отключение пароля без ключей заблокирует доступ к серверу."
    if confirm "Сгенерировать новый SSH-ключ (ed25519) прямо сейчас и сохранить приватный ключ в файл?"; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "root@$(hostname)" >/dev/null 2>&1
        cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys

        KEY_FILE="/root/GENERATED_PRIVATE_KEY.txt"
        cp /root/.ssh/id_ed25519 "$KEY_FILE"
        chmod 400 "$KEY_FILE"

        echo ""
        echo -e "${RED}=========================================================================${NC}"
        echo -e "${RED}  ВНИМАНИЕ! Приватный ключ сохранён в файл: ${KEY_FILE}  ${NC}"
        echo -e "${RED}  СКОПИРУЙТЕ ЕГО ОТТУДА И УДАЛИТЕ ФАЙЛ ПОСЛЕ НАСТРОЙКИ КЛИЕНТА!          ${NC}"
        echo -e "${RED}  Без этого файла вы НЕ СМОЖЕТЕ войти на сервер после отключения паролей. ${NC}"
        echo -e "${RED}=========================================================================${NC}"
        echo ""

        if confirm "Вы скопировали приватный ключ и готовы отключить вход по паролю?"; then
            DISABLE_PASSWORD="yes"
            if [ -n "$NEW_USER" ] && [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
                install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/${NEW_USER}/.ssh"
                install -m 600 -o "$NEW_USER" -g "$NEW_USER" \
                    /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
            fi
        else
            warn "Вход по паролю оставлен включенным. Настройте ключи вручную позже."
        fi
    else
        warn "Генерация ключей отменена. Вход по паролю останется включенным."
    fi
fi

# --- 4.3. Смена порта SSH ---
NEW_SSH_PORT=""
if confirm "Сменить стандартный SSH-порт (22)?"; then
    for _ in $(seq 1 20); do
        CANDIDATE=$(shuf -i 10000-60000 -n 1)
        if ! ss -tln | grep -q ":${CANDIDATE} "; then
            NEW_SSH_PORT="$CANDIDATE"
            break
        fi
    done
    [ -z "$NEW_SSH_PORT" ] && { err "Не удалось найти свободный порт после 20 попыток"; exit 1; }

    echo "$NEW_SSH_PORT" > /root/.new_ssh_port
    chmod 600 /root/.new_ssh_port
    log "Новый SSH-порт: ${NEW_SSH_PORT} (сохранён в /root/.new_ssh_port)"
fi

# --- 4.4. Записываем hardening-конфиг ---
if [ -n "$NEW_USER" ]; then
    ROOT_LOGIN_VAL="no"
else
    ROOT_LOGIN_VAL="prohibit-password"
fi

cat > "$HARDENING_CONF" <<EOF
# Сгенерировано hardening-скриптом $(date -Iseconds)
Protocol 2

# Аутентификация
PermitRootLogin ${ROOT_LOGIN_VAL}
PasswordAuthentication ${DISABLE_PASSWORD}
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
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

if [ -n "$NEW_USER" ]; then
    echo "AllowUsers ${NEW_USER}" >> "$HARDENING_CONF"
fi

if [ -n "$NEW_SSH_PORT" ]; then
    echo "Port ${NEW_SSH_PORT}" >> "$HARDENING_CONF"
fi

if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$SSHD_CONFIG"; then
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSHD_CONFIG"
fi

chmod 600 "$SSHD_CONFIG"
chmod 600 "$HARDENING_CONF"

if ! sshd -t; then
    err "Ошибка в конфиге SSH. Откатываем hardening-конфиг."
    rm -f "$HARDENING_CONF"
    exit 1
fi
log "Конфигурация SSH прошла проверку (sshd -t)"

# ============================================================
#  5. UFW Firewall (ПРАВИЛА ГОТОВИМ, НО НЕ ВКЛЮЧАЕМ!)  # ИЗМЕНЕНО (v2.5)
# ============================================================
log "[5/9] Подготовка правил UFW (включение — в самом конце)..."

sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw

# Сбрасываем предыдущие правила. Пока UFW выключен — сессия не оборвётся.
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# --- Определяем порт ТЕКУЩЕЙ SSH-сессии ---
CURRENT_SSH_PORT=""
if [ -n "${SSH_CONNECTION:-}" ]; then
    CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
fi

if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=$(ss -tnp state established '( dport = :22 or sport = :22 )' 2>/dev/null \
        | awk 'NR==1 {for(i=1;i<=NF;i++) if($i ~ /:/) {split($i,a,":"); print a[length(a)]; exit}}')
fi

CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
log "Текущий SSH-порт сессии: ${CURRENT_SSH_PORT}"

# --- Открываем порт текущей сессии (чтобы не потерять доступ) ---
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    ufw limit "${CURRENT_SSH_PORT}"/tcp comment 'SSH OLD (temporary)'
    warn "Добавлено правило: старый SSH-порт ${CURRENT_SSH_PORT} (временно)."
fi

# --- Открываем новый (или текущий) SSH-порт ---
if [ -n "$NEW_SSH_PORT" ]; then
    ufw limit "${NEW_SSH_PORT}"/tcp comment 'SSH (limited)'
else
    ufw limit 22/tcp comment 'SSH (limited)'
fi

ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'QUIC/Hysteria2'

info "Правила UFW подготовлены. Включение произойдёт в самом конце скрипта."

# ============================================================
#  6. Fail2Ban
# ============================================================
log "[6/9] Настройка Fail2Ban..."
backup_file /etc/fail2ban/jail.local

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
ignoreip           = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${NEW_SSH_PORT:-22}
filter   = sshd
maxretry = 3
EOF

systemctl enable fail2ban
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd 2>/dev/null || warn "fail2ban ещё не видит sshd (нормально, если журнал пуст)"

# ============================================================
#  7. Sysctl-hardening
# ============================================================
log "[7/9] Настройка ядра (sysctl)..."

SYSCTL_CONF="/etc/sysctl.d/99-hardening.conf"
cat > "$SYSCTL_CONF" <<'EOF'
# --- Сетевая защита ---
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

# --- Логирование подозрительных пакетов ---
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- Защита от распространённых атак и оптимизация ---
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

# ============================================================
#  8. Автообновления безопасности
# ============================================================
log "[8/9] Настройка unattended-upgrades..."

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades
systemctl restart unattended-upgrades

if confirm "Разрешить автоматическую перезагрузку после обновлений ядра (в 04:00)?"; then
    cat > /etc/apt/apt.conf.d/51unattended-upgrades-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
    log "Автоматическая перезагрузка включена."
else
    log "Автоматическая перезагрузка отключена."
fi

# ============================================================
#  9. Финальные проверки и права
# ============================================================
log "[9/9] Финальные штрихи..."

chmod 700 /root
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

rkhunter --update >/dev/null 2>&1 || true
rkhunter --propupd >/dev/null 2>&1 || true
log "База rkhunter обновлена."

# ============================================================
#  ИТОГОВАЯ СВОДКА (ПЕРЕД ВКЛЮЧЕНИЕМ UFW И ПЕРЕЗАПУСКОМ SSH!)  # ИЗМЕНЕНО (v2.5)
# ============================================================
PUBLIC_IP="$(get_public_ip)"
FINAL_PORT="${NEW_SSH_PORT:-22}"
FINAL_USER="${NEW_USER:-root}"

wait

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}           НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА!                     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}📋 ИТОГОВАЯ КОНФИГУРАЦИЯ:${NC}"
echo -e "  • IP-адрес сервера:             ${GREEN}${PUBLIC_IP}${NC}"
echo -e "  • SSH-порт (новый):             ${RED}${FINAL_PORT}${NC}"
echo -e "  • Пользователь для входа:       ${GREEN}${FINAL_USER}${NC}"
echo -e "  • Root login по SSH:            ${RED}ограничен ключами или отключен${NC}"
echo -e "  • Password authentication:      ${RED}${DISABLE_PASSWORD}${NC}"
echo -e "  • Лог скрипта:                  ${LOG_FILE}"
if [ -f "/root/GENERATED_PRIVATE_KEY.txt" ]; then
    echo -e "  • ПРИВАТНЫЙ КЛЮЧ СОХРАНЕН В:    ${RED}/root/GENERATED_PRIVATE_KEY.txt${NC}"
fi
if [ -n "$NEW_SSH_PORT" ]; then
    echo -e "  • Порт сохранён в:              /root/.new_ssh_port"
fi
echo ""
echo -e "${YELLOW}🔗 КОМАНДА ДЛЯ ПОДКЛЮЧЕНИЯ (скопируйте!):${NC}"
echo -e "  ${GREEN}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
echo ""

# --- Показываем будущие правила UFW и запрашиваем подтверждение ---  # ИЗМЕНЕНО (v2.5)
echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}📋 ПРАВИЛА FIREWALL (UFW), КОТОРЫЕ СЕЙЧАС БУДУТ ПРИМЕНЕНЫ:${NC}"
echo -e "${YELLOW}============================================================${NC}"
ufw status verbose
echo -e "${YELLOW}============================================================${NC}"
echo ""

if ! confirm "Применить правила UFW и перезапустить SSH?"; then
    warn "Применение правил UFW отменено пользователем."
    warn "Файервол остаётся выключенным. Включите позже: ufw enable"
    warn "Перезапуск SSH также отменён. Применить настройки: systemctl reload ssh"
    exit 0
fi

# ============================================================
#  10. ВКЛЮЧЕНИЕ UFW (теперь безопасно — правила уже готовы)  # ИЗМЕНЕНО (v2.5)
# ============================================================
log "Применение правил UFW..."
ufw --force enable
log "UFW успешно включён."

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}⚠️  ВНИМАНИЕ! СЕЙЧАС ПРОИЗОЙДЁТ ПЕРЕЗАПУСК SSH              ${NC}"
echo -e "${RED}============================================================${NC}"
echo -e "${RED}• Откройте НОВОЕ окно терминала и проверьте вход.           ${NC}"
echo -e "${RED}• Только ПОСЛЕ успешной проверки закрывайте эту сессию.     ${NC}"
echo -e "${RED}• Если потеряли доступ — используйте VNC-консоль хостинга.  ${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

# Перезапуск SSH — ПОСЛЕДНИМ шагом
service_restart_or_reload_ssh

echo ""
echo -e "${GREEN}✅ SSH успешно перезапущен.${NC}"
echo ""

# ============================================================
#  АВТОМАТИЧЕСКОЕ ЗАКРЫТИЕ СТАРОГО ПОРТА
# ============================================================
if [ -n "$NEW_SSH_PORT" ] && [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}🔐 АВТОМАТИЧЕСКОЕ ЗАКРЫТИЕ СТАРОГО ПОРТА                   ${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}Старый порт ${CURRENT_SSH_PORT} временно открыт для сохранения текущей сессии.${NC}"
    echo -e "${YELLOW}После подтверждения он будет автоматически закрыт.${NC}"
    echo ""

    if confirm "Вы успешно проверили подключение через новый порт ${FINAL_PORT}?"; then
        log "Закрываем старый SSH-порт ${CURRENT_SSH_PORT}..."
        ufw delete limit "${CURRENT_SSH_PORT}"/tcp >/dev/null 2>&1
        log "Старый порт ${CURRENT_SSH_PORT} успешно закрыт."
        echo ""
        echo -e "${GREEN}✅ Теперь доступен только новый порт: ${FINAL_PORT}${NC}"
    else
        warn "Закрытие старого порта отменено."
        warn "Вы можете закрыть его позже командой: ufw delete limit ${CURRENT_SSH_PORT}/tcp"
    fi
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}           НАСТРОЙКА ПОЛНОСТЬЮ ЗАВЕРШЕНА!                   ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${GREEN}✅ Сервер настроен и защищён.${NC}"
echo -e "${GREEN}   Используйте команду для подключения:${NC}"
echo -e "   ${GREEN}ssh -p ${FINAL_PORT} ${FINAL_USER}@${PUBLIC_IP}${NC}"
echo ""
if [ -f "/root/GENERATED_PRIVATE_KEY.txt" ]; then
    echo -e "${YELLOW}⚠️  Не забудьте удалить файл с приватным ключом:${NC}"
    echo -e "   ${RED}sudo rm -f /root/GENERATED_PRIVATE_KEY.txt${NC}"
    echo ""
fi
echo -e "${GREEN}Спасибо за использование скрипта!${NC}"
echo ""