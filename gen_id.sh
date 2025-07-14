#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Скрипт для генерації кількох нод у Nexus,
# автоматичного клонування/оновлення та збірки Nexus CLI,
# перевірки/створення користувача та збереження
# списку NODE_IDS у конфіг-файлі.
# ------------------------------------------------------------------

# -- Налаштування --
REPO_URL="https://github.com/nexus-xyz/nexus-cli.git"
PROJECT_DIR="$HOME/nexus-cli"
BUILD_DIR="$PROJECT_DIR/clients/cli"
CLI_BIN="$BUILD_DIR/target/release/nexus-network"
ENV_FILE="$HOME/nexus-nodes.env"
CONFIG_JSON="$HOME/.nexus/config.json"

# 1) ==== Клонування або оновлення репозиторію ====
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo "[+] Репозиторій не знайдено або не гіт. Клоную $REPO_URL → $PROJECT_DIR..."
  git clone "$REPO_URL" "$PROJECT_DIR"
else
  echo "[+] Оновлення репозиторію у $PROJECT_DIR..."
  cd "$PROJECT_DIR"
  git fetch origin
  git reset --hard origin/main
fi

# 2) ==== Збірка CLI (release) ====
cd "$PROJECT_DIR"
LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

if [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]] || [[ ! -x "$CLI_BIN" ]]; then
  echo "[+] Збираю Nexus CLI..."
  cd "$BUILD_DIR"
  cargo build --release
else
  echo "[+] Збірка не потрібна."
fi

# 3) Перевірка наявності бінарника
if [[ ! -x "$CLI_BIN" ]]; then
  echo "❌ Помилка: не знайдено $CLI_BIN" >&2
  exit 1
fi
echo "[+] Використовуємо CLI: $CLI_BIN"

# 4) Перевірка/створення користувача
if [[ -f "$CONFIG_JSON" ]]; then
  WALLET_ADDRESS=$(grep -oE '"wallet_address"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]+"' "$CONFIG_JSON" \
    | grep -oE '0x[0-9a-fA-F]+') || true
  echo "[+] Знайдено конфіг: $CONFIG_JSON"
  echo "    wallet_address = $WALLET_ADDRESS"
else
  read -rp "Введіть WALLET_ADDRESS для реєстрації: " WALLET_ADDRESS
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Регістрація користувача..."
  $CLI_BIN register-user --wallet-address "$WALLET_ADDRESS"
  echo "[+] Користувача зареєстровано. Створено $CONFIG_JSON"
fi

# 5) Підготовка ENV_FILE
if [[ ! -f "$ENV_FILE" ]]; then
  echo "NODE_IDS=" > "$ENV_FILE"
  echo "[+] Створено $ENV_FILE"
fi
# Завантажуємо старі ID
source "$ENV_FILE"
OLD_IDS="${NODE_IDS:-}"

# 6) Запит кількості нод
read -rp "Скільки нод потрібно зареєструвати? " COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
  echo "Некоректна кількість: $COUNT" >&2
  exit 1
fi

# 7) Реєстрація з ретраями
NEW_IDS=()
echo "Починаємо реєстрацію $COUNT нод..."
for ((i=1; i<=COUNT; i++)); do
  attempt=1
  success=false
  until (( attempt > 3 )); do
    echo "-> Нода #$i (спроба $attempt)..."
    set +e
    OUTPUT=$($CLI_BIN register-node 2>&1)
    STATUS=$?
    set -e
    if (( STATUS == 0 )); then
      if ID=$(echo "$OUTPUT" | grep -oE 'Node registered successfully with ID: [0-9]+' | grep -oE '[0-9]+'); then
        echo "   Отримано ID: $ID"
        NEW_IDS+=("$ID")
        success=true
        break
      else
        echo "   ❌ Не вдалося витягнути ID. Відповідь CLI:" >&2
        echo "$OUTPUT" >&2
      fi
    else
      echo "   ❌ Помилка реєстрації: $OUTPUT" >&2
    fi
    ((attempt++))
    sleep 5
  done

  if [[ $success != true ]]; then
    echo "❌ Нода #$i не зареєстрована після 3 спроб, припиняю."
    break
  fi
done

# 8) Об’єднуємо старі та нові ID (без дублікатів)
ALL_IDS=()
for id in ${OLD_IDS//,/ }; do
  [[ -n "$id" ]] && ALL_IDS+=("$id")
done
for id in "${NEW_IDS[@]}"; do
  if [[ ! " ${ALL_IDS[*]} " =~ " $id " ]]; then
    ALL_IDS+=("$id")
  fi
done

# 9) Записуємо в ENV_FILE
JOINED=$(IFS=,; echo "${ALL_IDS[*]}")
echo "NODE_IDS=$JOINED" > "$ENV_FILE"
echo "[+] Оновлено $ENV_FILE: NODE_IDS=$JOINED"
echo "Готово! Всього нод у конфігурації: ${#ALL_IDS[@]}"

# 10) Завантаження nexus.sh та інструкція
wget -q -O nexus.sh https://raw.githubusercontent.com/mgpwnz/Nexus/refs/heads/main/nexus.sh
chmod +x nexus.sh
echo "Щоб запустити ноди, використовуйте: ./nexus.sh"
