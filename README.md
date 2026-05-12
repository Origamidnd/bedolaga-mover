# bedolaga-mover

Инструмент для переноса стека **Bedolaga Bot + Cabinet + remnawave-admin** на новый VPS.

## Быстрый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Origamidnd/bedolaga-mover/main/bedolaga-mover.sh)
```

Запускай на любом сервере — скрипт скачается и сразу откроет меню.

```
  ██████╗ ███████╗██████╗  ██████╗ ██╗      █████╗  ██████╗  █████╗
  ██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║     ██╔══██╗██╔════╝ ██╔══██╗
  ██████╔╝█████╗  ██║  ██║██║   ██║██║     ███████║██║  ███╗███████║
  ██╔══██╗██╔══╝  ██║  ██║██║   ██║██║     ██╔══██║██║   ██║██╔══██║
  ██████╔╝███████╗██████╔╝╚██████╔╝███████╗██║  ██║╚██████╔╝██║  ██║
  ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝

                 M O V E R  —  инструмент переноса

  Что делаем?

  1) 📦 Упаковать      — я на СТАРОМ сервере, хочу собрать архив
  2) 🚀 Распаковать    — я на НОВОМ сервере, архив уже загружен
  0) Выход
```

## Что переносится

| Компонент | Данные |
|-----------|--------|
| Bedolaga Bot | PostgreSQL БД, `.env`, `uploads/`, `locales/`, `vpn_logo.png` |
| Cabinet | `.env` |
| remnawave-admin | PostgreSQL БД, `.env`, `frontend-static/` |
| Caddy | `Caddyfile` |

## Требования к новому серверу

```bash
# Docker
curl -fsSL https://get.docker.com | sh

# Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install caddy -y
```

## Использование

### Шаг 1 — На старом сервере

```bash
bash bedolaga-mover.sh
# → выбрать «1) Упаковать»
```

Скрипт создаёт `/root/bedolaga_migration.tar.gz`. Бот при этом не останавливается.

Если папки не стандартные:
```bash
BOT_DIR=/opt/mybot CABINET_DIR=/opt/cabinet bash bedolaga-mover.sh
```

### Шаг 2 — Передать архив

```bash
scp /root/bedolaga_migration.tar.gz root@NEW_IP:/root/
```

### Шаг 3 — На новом сервере

```bash
bash bedolaga-mover.sh
# → выбрать «2) Распаковать»
```

Скрипт сам клонирует репозитории, восстановит БД, поднимет контейнеры и перезапустит Caddy.

### Шаг 4 — Переключить DNS

Меняем A-записи всех доменов на IP нового сервера. Caddy автоматически получит TLS-сертификаты.

```bash
# Проверить что сертификаты получены
journalctl -u caddy -n 30 | grep "obtained"
```

### Шаг 5 — Остановить бота на старом сервере

```bash
cd /root/remnawave-bedolaga-telegram-bot
docker compose stop bot
```

> Старый сервер остаётся включённым как резерв. Если что-то пойдёт не так — `docker compose up -d` и DNS обратно.

## Откат

```bash
# На старом сервере
cd /root/remnawave-bedolaga-telegram-bot
docker compose up -d
# Поменяй DNS обратно на IP старого сервера
```

## Известные нюансы

**remnawave-admin конфликт:** Если бот запущен одновременно на старом и новом серверах — Telegram выдаст `TelegramConflictError`. Остановить на старом:
```bash
cd ~/remnawave-admin && docker compose stop bot
```

**Права на папки бота:** Если бот не стартует с `PermissionError`:
```bash
chmod -R 777 /root/remnawave-bedolaga-telegram-bot/logs
chmod -R 777 /root/remnawave-bedolaga-telegram-bot/data
```

**DNS TTL:** Проверить что изменение применилось можно напрямую через NS:
```bash
dig +short yourdomain.com @ns1.reg.ru
```

## Совместимость

Протестировано:
- Bedolaga Bot v3.54.0 + Cabinet v1.46.0
- remnawave-admin (Case211)
- Docker 29.x + Compose v5.x
- Caddy v2.11.x
- Ubuntu 22.04 / 24.04
