#!/bin/bash
# =============================================================
#  bedolaga-mover — инструмент переноса Bedolaga стека
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Конфигурация ──────────────────────────────────────────────
BOT_DIR="${BOT_DIR:-/root/remnawave-bedolaga-telegram-bot}"
CABINET_DIR="${CABINET_DIR:-/opt/bedolaga-cabinet}"
RMADMIN_DIR="${RMADMIN_DIR:-/root/remnawave-admin}"
ARCHIVE="/root/bedolaga_migration.tar.gz"
# ─────────────────────────────────────────────────────────────

log()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

header() {
  clear
  echo ""
  echo -e "${CYAN}${BOLD}  ██████╗ ███████╗██████╗  ██████╗ ██╗      █████╗  ██████╗  █████╗ ${NC}"
  echo -e "${CYAN}${BOLD}  ██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║     ██╔══██╗██╔════╝ ██╔══██╗${NC}"
  echo -e "${CYAN}${BOLD}  ██████╔╝█████╗  ██║  ██║██║   ██║██║     ███████║██║  ███╗███████║${NC}"
  echo -e "${CYAN}${BOLD}  ██╔══██╗██╔══╝  ██║  ██║██║   ██║██║     ██╔══██║██║   ██║██╔══██║${NC}"
  echo -e "${CYAN}${BOLD}  ██████╔╝███████╗██████╔╝╚██████╔╝███████╗██║  ██║╚██████╔╝██║  ██║${NC}"
  echo -e "${CYAN}${BOLD}  ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝${NC}"
  echo ""
  echo -e "${BLUE}${BOLD}                   M O V E R  —  инструмент переноса${NC}"
  echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo ""
}

# =============================================================
# PACK — упаковка на старом сервере
# Останавливает ботов, снимает дамп, оставляет только БД
# =============================================================
cmd_pack() {
  header
  echo -e "  ${BOLD}📦 Упаковка — подготовка к переносу${NC}"
  echo -e "  ${CYAN}─────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}Боты будут остановлены. БД (postgres/redis) останутся работать.${NC}"
  echo -e "  ${YELLOW}На новом сервере конфликтов не будет.${NC}"
  echo ""
  read -rp "  Продолжить? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Отменено"; return; }
  echo ""

  [ ! -d "$BOT_DIR" ]      && fail "Папка бота не найдена: $BOT_DIR"
  [ ! -f "$BOT_DIR/.env" ] && fail ".env бота не найден"
  command -v docker &>/dev/null || fail "Docker не установлен"

  WORK_DIR=$(mktemp -d)
  trap "rm -rf '$WORK_DIR'" EXIT

  # ── Останавливаем ботов ───────────────────────────────────
  log "Останавливаем Bedolaga бота..."
  cd "$BOT_DIR"
  docker compose stop bot
  ok "Bedolaga бот остановлен"

  if [ -d "$RMADMIN_DIR" ] && [ -f "$RMADMIN_DIR/docker-compose.yml" ]; then
    log "Останавливаем remnawave-admin бота..."
    cd "$RMADMIN_DIR"
    docker compose stop bot 2>/dev/null && ok "remnawave-admin бот остановлен" \
      || warn "remnawave-admin бот не найден или уже остановлен"
  fi

  # ── БД Bedolaga бота ─────────────────────────────────────
  log "Снимаем дамп БД бота..."
  source <(grep -E "^POSTGRES_(USER|DB)" "$BOT_DIR/.env" 2>/dev/null || true)
  POSTGRES_USER="${POSTGRES_USER:-remnawave_user}"
  POSTGRES_DB="${POSTGRES_DB:-remnawave_bot}"

  cd "$BOT_DIR"
  docker compose exec -T postgres pg_dump -Fc \
    -U "$POSTGRES_USER" "$POSTGRES_DB" \
    > "$WORK_DIR/bot_db.dump"
  [ -s "$WORK_DIR/bot_db.dump" ] || fail "Дамп БД пустой"
  ok "Дамп БД бота: $(du -sh "$WORK_DIR/bot_db.dump" | cut -f1)"

  # ── Файлы бота ────────────────────────────────────────────
  cp "$BOT_DIR/.env" "$WORK_DIR/bot.env"
  for d in uploads locales; do
    [ -d "$BOT_DIR/$d" ] && cp -r "$BOT_DIR/$d" "$WORK_DIR/bot_$d" && ok "Скопировано: $d"
  done
  [ -f "$BOT_DIR/vpn_logo.png" ] && cp "$BOT_DIR/vpn_logo.png" "$WORK_DIR/" && ok "Скопировано: vpn_logo.png"

  # ── Cabinet ───────────────────────────────────────────────
  if [ -f "$CABINET_DIR/.env" ]; then
    cp "$CABINET_DIR/.env" "$WORK_DIR/cabinet.env" && ok "Скопировано: cabinet .env"
  else
    warn "Cabinet .env не найден — пропускаем"
  fi

  # ── remnawave-admin ───────────────────────────────────────
  if [ -d "$RMADMIN_DIR" ] && [ -f "$RMADMIN_DIR/docker-compose.yml" ]; then
    log "Снимаем дамп БД remnawave-admin..."
    source <(grep -E "^POSTGRES_(USER|DB)" "$RMADMIN_DIR/.env" 2>/dev/null || true)
    RA_USER="${POSTGRES_USER:-postgres}"
    RA_DB="${POSTGRES_DB:-remnawave_bot}"

    cd "$RMADMIN_DIR"
    docker compose exec -T remnawave-admin-db pg_dump -Fc \
      -U "$RA_USER" "$RA_DB" \
      > "$WORK_DIR/rmadmin_db.dump" 2>/dev/null || warn "Не удалось снять дамп rmadmin БД"
    [ -s "$WORK_DIR/rmadmin_db.dump" ] && ok "Дамп rmadmin БД: $(du -sh "$WORK_DIR/rmadmin_db.dump" | cut -f1)"

    cp "$RMADMIN_DIR/.env" "$WORK_DIR/rmadmin.env" 2>/dev/null && ok "Скопировано: rmadmin .env"
    [ -d "$RMADMIN_DIR/frontend-static" ] && \
      cp -r "$RMADMIN_DIR/frontend-static" "$WORK_DIR/rmadmin_frontend_static" && \
      ok "Скопировано: rmadmin frontend-static"
  else
    warn "remnawave-admin не найден — пропускаем"
  fi

  # ── Caddy ─────────────────────────────────────────────────
  if [ -f "/etc/caddy/Caddyfile" ]; then
    cp "/etc/caddy/Caddyfile" "$WORK_DIR/Caddyfile" && ok "Скопировано: Caddyfile"
  else
    warn "Caddyfile не найден — пропускаем"
  fi

  # ── Архив ─────────────────────────────────────────────────
  log "Создаём архив..."
  tar -czf "$ARCHIVE" -C "$WORK_DIR" .
  ok "Архив готов: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"

  echo ""
  echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}║  Упаковка завершена!                                     ║${NC}"
  echo -e "  ${GREEN}║                                                          ║${NC}"
  echo -e "  ${GREEN}║  Боты остановлены. БД работает.                         ║${NC}"
  echo -e "  ${GREEN}║                                                          ║${NC}"
  echo -e "  ${GREEN}║  Передай архив на новый сервер:                          ║${NC}"
  echo -e "  ${GREEN}║  ${CYAN}scp $ARCHIVE root@NEW_IP:/root/${GREEN}    ║${NC}"
  echo -e "  ${GREEN}║                                                          ║${NC}"
  echo -e "  ${GREEN}║  Затем на новом сервере запусти скрипт и                 ║${NC}"
  echo -e "  ${GREEN}║  выбери «Распаковать на новом сервере»                   ║${NC}"
  echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# =============================================================
# UNPACK — разворачивание на новом сервере
# =============================================================
cmd_unpack() {
  header
  echo -e "  ${BOLD}🚀 Распаковать на новом сервере${NC}"
  echo -e "  ${CYAN}────────────────────────────────${NC}"
  echo ""

  command -v docker &>/dev/null || fail "Docker не установлен. Запусти: curl -fsSL https://get.docker.com | sh"
  command -v caddy  &>/dev/null || fail "Caddy не установлен. См. README.md"
  [ -f "$ARCHIVE" ]             || fail "Архив не найден: $ARCHIVE"

  WORK_DIR=$(mktemp -d)
  trap "rm -rf '$WORK_DIR'" EXIT
  tar -xzf "$ARCHIVE" -C "$WORK_DIR"
  SRC="$WORK_DIR"
  ok "Архив распакован"

  # ── Bedolaga бот ─────────────────────────────────────────
  log "Разворачиваем Bedolaga бота..."
  if [ ! -d "$BOT_DIR/.git" ]; then
    git clone https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git "$BOT_DIR"
    ok "Репозиторий склонирован"
  fi

  cp "$SRC/bot.env" "$BOT_DIR/.env"
  for d in uploads locales; do
    [ -d "$SRC/bot_$d" ] && cp -r "$SRC/bot_$d" "$BOT_DIR/$d" && ok "Восстановлено: $d"
  done
  [ -f "$SRC/vpn_logo.png" ] && cp "$SRC/vpn_logo.png" "$BOT_DIR/"

  mkdir -p "$BOT_DIR/logs" "$BOT_DIR/data"
  chmod -R 777 "$BOT_DIR/logs" "$BOT_DIR/data"

  log "Поднимаем postgres и redis..."
  cd "$BOT_DIR"
  docker compose up -d postgres redis
  log "Ждём готовности БД (15 сек)..."
  sleep 15

  log "Восстанавливаем БД бота..."
  source <(grep -E "^POSTGRES_(USER|DB)" "$BOT_DIR/.env" 2>/dev/null || true)
  POSTGRES_USER="${POSTGRES_USER:-remnawave_user}"
  POSTGRES_DB="${POSTGRES_DB:-remnawave_bot}"
  docker compose exec -T postgres pg_restore \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists \
    < "$SRC/bot_db.dump"
  ok "БД бота восстановлена"

  log "Собираем и запускаем бота..."
  docker compose build --quiet && docker compose up -d
  ok "Bedolaga бот запущен"

  # ── Cabinet ───────────────────────────────────────────────
  if [ -f "$SRC/cabinet.env" ]; then
    log "Разворачиваем Cabinet..."
    mkdir -p "$CABINET_DIR"
    cp "$SRC/cabinet.env" "$CABINET_DIR/.env"
    cat > "$CABINET_DIR/docker-compose.yml" << 'EOF'
services:
  cabinet-frontend:
    image: ghcr.io/bedolaga-dev/bedolaga-cabinet:latest
    container_name: cabinet_frontend
    restart: unless-stopped
    ports:
      - "3020:80"
    networks:
      - bot_network

networks:
  bot_network:
    external: true
    name: remnawave-bedolaga-telegram-bot_bot_network
EOF
    cd "$CABINET_DIR"
    docker compose pull --quiet && docker compose up -d
    ok "Cabinet запущен"
  else
    warn "cabinet.env не найден — Cabinet пропущен"
  fi

  # ── remnawave-admin ───────────────────────────────────────
  if [ -f "$SRC/rmadmin.env" ]; then
    log "Разворачиваем remnawave-admin..."
    if [ ! -d "$RMADMIN_DIR/.git" ]; then
      git clone https://github.com/Case211/remnawave-admin.git "$RMADMIN_DIR"
    fi

    cp "$SRC/rmadmin.env" "$RMADMIN_DIR/.env"
    [ -d "$SRC/rmadmin_frontend_static" ] && \
      cp -r "$SRC/rmadmin_frontend_static" "$RMADMIN_DIR/frontend-static"

    docker network create remnawave-network 2>/dev/null || true

    cd "$RMADMIN_DIR"
    docker compose up -d remnawave-admin-db
    log "Ждём готовности БД rmadmin (15 сек)..."
    sleep 15

    if [ -s "$SRC/rmadmin_db.dump" ]; then
      source <(grep -E "^POSTGRES_(USER|DB)" "$RMADMIN_DIR/.env" 2>/dev/null || true)
      RA_USER="${POSTGRES_USER:-postgres}"
      RA_DB="${POSTGRES_DB:-remnawave_bot}"
      docker compose exec -T remnawave-admin-db pg_restore \
        -U "$RA_USER" -d "$RA_DB" \
        --clean --if-exists \
        < "$SRC/rmadmin_db.dump"
      ok "БД remnawave-admin восстановлена"
    fi

    docker compose up -d
    ok "remnawave-admin запущен"
  else
    warn "rmadmin.env не найден — remnawave-admin пропущен"
  fi

  # ── Caddy ─────────────────────────────────────────────────
  if [ -f "$SRC/Caddyfile" ]; then
    cp "$SRC/Caddyfile" /etc/caddy/Caddyfile
    caddy validate --config /etc/caddy/Caddyfile &>/dev/null && \
      systemctl reload caddy && ok "Caddy перезапущен" || \
      warn "Ошибка в Caddyfile — проверь: caddy validate --config /etc/caddy/Caddyfile"
  else
    warn "Caddyfile не найден — настрой Caddy вручную"
  fi

  echo ""
  echo -e "  ${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}║  Готово! Что делать дальше:                          ║${NC}"
  echo -e "  ${GREEN}║  1. Смени DNS A-записи на IP этого сервера           ║${NC}"
  echo -e "  ${GREEN}║  2. Проверь TLS сертификаты:                         ║${NC}"
  echo -e "  ${GREEN}║     ${CYAN}journalctl -u caddy -n 20 | grep obtained${GREEN}     ║${NC}"
  echo -e "  ${GREEN}║  3. Старый сервер оставь включённым как резерв       ║${NC}"
  echo -e "  ${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Статус контейнеров:${NC}"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo ""
}

# =============================================================
# МЕНЮ
# =============================================================
main_menu() {
  while true; do
    header
    echo -e "  Что делаем?\n"
    echo -e "  ${GREEN}1)${NC} ${BOLD}📦 Упаковать${NC}      — я на СТАРОМ сервере, хочу перенести на новый"
    echo -e "  ${YELLOW}2)${NC} ${BOLD}🚀 Распаковать${NC}    — я на НОВОМ сервере, архив уже загружен"
    echo -e "  ${RED}0)${NC} ${BOLD}Выход${NC}"
    echo ""

    if [ -f "$ARCHIVE" ]; then
      echo -e "  ${YELLOW}ℹ  Найден архив: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))${NC}"
    fi
    echo ""

    read -rp "  Выбор [0-2]: " choice
    case "$choice" in
      1) cmd_pack   ; read -rp "  Нажми Enter для возврата в меню..." ;;
      2) cmd_unpack ; read -rp "  Нажми Enter для возврата в меню..." ;;
      0) echo "" ; exit 0 ;;
      *) warn "Неверный выбор" ; sleep 1 ;;
    esac
  done
}

main_menu
