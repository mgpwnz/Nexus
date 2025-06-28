#!/usr/bin/env bash
set -euo pipefail

# ==== Налаштування ====
REPO_URL="https://github.com/nexus-xyz/nexus-cli.git"
PROJECT_DIR="$HOME/nexus-cli"
BUILD_DIR="$PROJECT_DIR/clients/cli"
ENV_FILE="$HOME/nexus-nodes.env"

# ==== Клонування репо, якщо його нема ====
if [ ! -d "$PROJECT_DIR" ]; then
  echo "[+] Репозиторій не знайдено. Клоную..."
  git clone "$REPO_URL" "$PROJECT_DIR"
fi

# ==== Перевірка .env ====
if [ ! -f "$ENV_FILE" ]; then
  echo "[!] Файл $ENV_FILE не знайдено."
  read -rp "Хочеш створити його зараз? [y/N] " CREATE_ENV
  if [[ "$CREATE_ENV" =~ ^[Yy]$ ]]; then
    echo "NODE_IDS=" > "$ENV_FILE"
    echo "Файл $ENV_FILE створено. Зараз можна додати перші ID."
  else
    echo "Операцію скасовано."
    exit 1
  fi
fi

# ==== Зчитуємо NODE_IDs ====
export $(grep -v '^#' "$ENV_FILE" | xargs)
NODE_IDS="${NODE_IDS:-}"

# ==== Відображення наявних ID ====
if [ -z "$NODE_IDS" ]; then
  echo "[+] Поточні Node ID: (порожньо)"
else
  echo "[+] Поточні Node ID: $NODE_IDS"
fi

# ==== Пропозиція додати ID ====
read -rp "Хочеш додати ще ID до списку? [y/N] " ADD_IDS
if [[ "$ADD_IDS" =~ ^[Yy]$ ]]; then
  read -rp "Введи ID через кому (наприклад: ID1,ID2,ID3): " NEW_IDS
  if [ -z "$NODE_IDS" ]; then
    UPDATED_IDS="$NEW_IDS"
  else
    UPDATED_IDS="$NODE_IDS,$NEW_IDS"
  fi
  echo "NODE_IDS=$UPDATED_IDS" > "$ENV_FILE"
  echo "[+] Оновлено NODE_IDS у $ENV_FILE"
  NODE_IDS="$UPDATED_IDS"
fi

# ==== Повторно зчитуємо NODE_IDs після оновлення ====
IFS=',' read -r -a NODE_ID_ARRAY <<< "$NODE_IDS"

if [ "${#NODE_ID_ARRAY[@]}" -eq 0 ]; then
  echo "[-] Немає жодного Node ID. Додай у $ENV_FILE або перезапусти скрипт."
  exit 1
fi

# ==== Оновлення репо (якщо потрібно) ====
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

# ==== Збірка, якщо потрібно ====
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

echo "[✓] Усі ноди запущені у tmux!"
echo "Для перегляду сесії: tmux attach -t nexus-<ID>"
echo "Щоб від'єднатись: Ctrl+B, потім D"
