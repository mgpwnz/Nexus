#!/usr/bin/env bash
set -euo pipefail

# ==== Налаштування ====
REPO_URL="https://github.com/nexus-xyz/nexus-cli.git"
PROJECT_DIR="$HOME/nexus-cli"
BUILD_DIR="$PROJECT_DIR/clients/cli"
ENV_FILE="$HOME/nexus-nodes.env"

# ==== Перевірка .env ====
if [ ! -f "$ENV_FILE" ]; then
  echo "[!] Файл $ENV_FILE не знайдено. Створюю..."
  echo "NODE_IDS=" > "$ENV_FILE"
fi

# ==== Завантаження змінних ====
export $(grep -v '^#' "$ENV_FILE" | xargs || true)

# ==== Налаштування таймера ====
if [ "${DISABLE_NEXUS_TIMER:-}" != "true" ]; then
  if [[ -t 0 ]]; then
    echo
    echo "====================================================="
    echo "Бажаєш налаштувати автозапуск nexus.sh раз на 2 дні?"
    echo "====================================================="
    read -rp "Налаштувати таймер? [y/N] " SETUP_TIMER
  else
    SETUP_TIMER="n"
  fi

  if [[ "$SETUP_TIMER" =~ ^[Yy]$ ]]; then
    echo "[+] Створюю systemd таймер..."
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_USER_DIR"

    SERVICE_FILE="$SYSTEMD_USER_DIR/nexus-auto-update.service"
    TIMER_FILE="$SYSTEMD_USER_DIR/nexus-auto-update.timer"

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Автозапуск Nexus CLI

[Service]
Type=oneshot
ExecStart=$HOME/nexus.sh
EOF

    cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Запуск Nexus CLI раз на 2 дні

[Timer]
OnBootSec=10min
OnUnitActiveSec=2d
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now nexus-auto-update.timer

    echo "[✓] Таймер налаштовано!"
  else
    echo "DISABLE_NEXUS_TIMER=true" >> "$ENV_FILE"
    echo "[i] Автозапуск вимкнено. Щоб увімкнути — видали DISABLE_NEXUS_TIMER з $ENV_FILE."
  fi
fi

# ==== Пропозиція додати NODE_IDs ====
if [[ -t 0 ]]; then
  read -rp "Хочеш додати ще ID до списку? [y/N] " ADD_IDS
else
  ADD_IDS="n"
fi

NODE_IDS="${NODE_IDS:-}"

if [[ "$ADD_IDS" =~ ^[Yy]$ ]]; then
  read -rp "Введи ID через кому (наприклад: ID1,ID2,ID3): " NEW_IDS
  if [ -z "$NODE_IDS" ]; then
    UPDATED_IDS="$NEW_IDS"
  else
    UPDATED_IDS="$NODE_IDS,$NEW_IDS"
  fi
  echo "NODE_IDS=$UPDATED_IDS" > "$ENV_FILE"
  NODE_IDS="$UPDATED_IDS"
  echo "[+] Оновлено NODE_IDS у $ENV_FILE"
fi

# ==== Зчитуємо масив ====
IFS=',' read -r -a NODE_ID_ARRAY <<< "$NODE_IDS"

if [ "${#NODE_ID_ARRAY[@]}" -eq 0 ]; then
  echo "[-] Немає жодного Node ID. Додай у $ENV_FILE або перезапусти скрипт."
  exit 1
fi

echo "[+] Поточні Node ID: $NODE_IDS"

# ==== Клонування репо (якщо потрібно) ====
if [ ! -d "$PROJECT_DIR" ]; then
  echo "[+] Репозиторій не знайдено. Клоную..."
  git clone "$REPO_URL" "$PROJECT_DIR"
fi

# ==== Перевірка оновлень ====
cd "$PROJECT_DIR"
echo "[+] Перевірка оновлень репозиторію..."
git fetch

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

NEED_BUILD=0
if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
  echo "[+] Є оновлення. Оновлюю..."
  git pull
  NEED_BUILD=1
else
  echo "[+] Зміни відсутні."
fi

# ==== Збірка ====
if [ "$NEED_BUILD" -eq 1 ] || [ ! -f "$BUILD_DIR/target/release/nexus-network" ]; then
  echo "[+] Виконую збірку..."
  cd "$BUILD_DIR"
  cargo build --release
else
  echo "[+] Збірка не потрібна."
fi

# ==== Закриваємо старі tmux сесії ====
for id in "${NODE_ID_ARRAY[@]}"; do
  tmux kill-session -t "nexus-$id" 2>/dev/null || true
done

# ==== Запускаємо нові tmux сесії ====
for id in "${NODE_ID_ARRAY[@]}"; do
  echo "[+] Запускаю ноду $id у tmux-сесії nexus-$id"
  tmux new-session -d -s "nexus-$id" \
    "$BUILD_DIR/target/release/nexus-network start --node-id $id"
done

# ==== Перевіряємо, що всі tmux сесії активні ====
ALL_OK=true

for id in "${NODE_ID_ARRAY[@]}"; do
  if ! tmux has-session -t "nexus-$id" 2>/dev/null; then
    echo "[!] Сесія nexus-$id не запущена!"
    ALL_OK=false
  fi
done

if [ "$ALL_OK" = false ]; then
  echo "[!] Не всі сесії запустилися. Повторно запускаємо nexus.sh через 5 секунд..."
  sleep 5
  exec "$HOME/nexus.sh"
fi

echo "[✓] Усі ноди запущені у tmux!"
echo "Для перегляду сесії: tmux attach -t nexus-<ID>"
echo "Щоб від'єднатись: Ctrl+B, потім D"
