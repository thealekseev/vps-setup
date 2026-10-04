#!/bin/bash

# ============================================================
#  Скрипт базовой настройки и hardening Linux-сервера (v2.8)
#  Поддержка: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Запуск от имени root
#
#  Репозиторий: https://github.com/thealekseev/vps-setup
#
#  Изменения в v2.8:
#   - ДОБАВЛЕНО: функции step_start, run_timed, step_done для красивого вывода
#   - ФИКС: все read и confirm используют < /dev/tty (100% работа при curl | bash)
#   - ФИКС: get_public_ip принудительно использует IPv4 (-4)
#   - ФИКС: идеальная структура here-document для SSH и Fail2Ban
#   - УЛУЧШЕНО: расширенные и безопасные настройки jail.local для Fail2Ban
#   - ФИКС: добавлен wait в конце для гарантии записи всего лога
# ============================================================

set -uo pipefail

# ---------- Цвета ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Логирование ----------
LOG_FILE="/var/log/server-hardening.log"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ---------- Управление шагами ----------
STEP=0
TOTAL_STEPS=10
START_TIME=0

step_start() {
    ((STEP++))
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  [$STEP/$TOTAL_STEPS] $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    START_TIME=$(date +%s)
}

run_timed() {
    local desc="$1"
    shift
    echo -e "  ${CYAN}↳${NC} $desc"
    "$@"
}

step_done() {
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    echo -e "${GREEN}  [OK] Выполнено за ${DURATION} сек.${NC}"
}

# ---------- Вспомогательные функции ----------
confirm() {
    local prompt="$1"
    local answer
    # КРИТИЧЕСКИ ВАЖНО: < /dev/tty обеспечивает работу при запуске через curl | bash
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

    if systemctl reload "$unit" 2>/dev/null; then
        log "SSH успешно перезагружен (reload) (${unit})"
        return 0
    else
        err "Не удалось сделать reload, пробуем restart..."
        if systemctl restart "$unit"; then
            log "SSH успешно перезапущен (restart) (${unit})"
            return 0
        else
            err "Не удалось перезапустить SSH!"
            return 