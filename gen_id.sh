#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Скрипт для генерації кількох нод у Nexus,
# автоматичного клонування/оновлення та збірки Nexus CLI,
# перевірки/створення користувача (register-user) та збереження
# списку NODE_IDS у конфіг-файлі.
# ------------------------------------------------------------------

# -- Налаштування --
REPO_URL="https://github.com/nexus-xyz/nexus-cli.git"
PROJECT_DIR="$HOME/nexus-cli"
BUILD_DIR="$PROJECT_DIR/clients/cli"
CLI_BIN="$BUILD_DIR/target/release/nexus-network"
ENV_FILE="$HOME/nexus-nodes.env"
CONFIG_JSON="$HOME/.nexus/config.json"

# 1) Клонування або оновлення репозиторію Nexus CLI
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "[+] Репозиторій не знайдено. Клоную $REPO_URL → $PROJECT_DIR..."
  git clone "$REPO_URL" "$PROJECT_DIR"
else
  echo "[+] Оновлення репозиторію у $PROJECT_DIR..."
  cd "$PROJECT_DIR"
  git fetch origin
  git reset --hard origin/main
fi

# 2) Збірка Nexus CLI (release)
echo "[+] Збираю Nexus CLI (cargo build --release)..."
cd "$BUILD_DIR"
/root/.cargo/bin/cargo build --release

# 3) Перевірка наявності бінарника CLI
if [[ ! -x "$CLI_BIN" ]]; then
  echo "❌ Помилка: не знайдено зібраний бінарник: $CLI_BIN" >&2
  exit 1
fi

echo "[+] Використовуємо CLI: $CLI_BIN"

# 4) Перевірка/створення користувача
if [[ -f "$CONFIG_JSON" ]]; then
  # Якщо існує, виводимо знайдений wallet_address
  WALLET_ADDRESS=$(grep -oE '"wallet_address"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_JSON" \
    | grep -oE '0x[0-9a-fA-F]+' ) || true
  echo "[+] Знайдено конфіг користувача: $CONFIG_JSON"
  echo "    wallet_address = $WALLET_ADDRESS"
else
  # Якщо немає, створюємо користувача
  read -rp "Введіть WALLET_ADDRESS для реєстрації користувача: " WALLET_ADDRESS
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Регістрація користувача з адресою $WALLET_ADDRESS..."
  $CLI_BIN register-user --wallet-address "$WALLET_ADDRESS"
  echo "[+] Користувача зареєстровано. Створено $CONFIG_JSON"
fi

# 5) Створення ENV_FILE, якщо відсутній
if [[ ! -f "$ENV_FILE" ]]; then
  echo "NODE_IDS=" > "$ENV_FILE"
  echo "[+] Створено новий файл конфігурації: $ENV_FILE"
fi

# 6) Запит кількості нод для реєстрації
read -rp "Скільки нод потрібно зареєструвати? " COUNT
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
  echo "Некоректна кількість: $COUNT" >&2
  exit 1
fi

# 7) Завантаження існуючих ID
source "$ENV_FILE"
OLD_IDS="${NODE_IDS:-}"
NEW_IDS=()

echo "Починаємо реєстрацію $COUNT нод..."
for ((i=1; i<=COUNT; i++)); do
  echo "-> Реєструємо ноду #$i..."
  OUTPUT=$($CLI_BIN register-node)
  if ID=$(echo "$OUTPUT" | grep -oE 'Node registered successfully with ID: [0-9]+' | grep -oE '[0-9]+'); then
    echo "   Отримано ID: $ID"
    NEW_IDS+=("$ID")
  else
    echo "❌ Не вдалося витягнути ID з виводу:" >&2
    echo "$OUTPUT" >&2
    exit 1
  fi
done

# 8) Об'єднання старих та нових ID, усунення дублів
ALL_IDS=()
for id in ${OLD_IDS//,/ }; do
  [[ -n "$id" ]] && ALL_IDS+=("$id")
done
for id in "${NEW_IDS[@]}"; do
  if [[ ! " ${ALL_IDS[*]} " =~ " $id " ]]; then
    ALL_IDS+=("$id")
  fi
done

# 9) Запис у ENV_FILE
JOINED=$(IFS=,; echo "${ALL_IDS[*]}")
echo "NODE_IDS=$JOINED" > "$ENV_FILE"
echo "Файл $ENV_FILE оновлено: NODE_IDS=$JOINED"

echo "Готово! Всього нод у конфігурації: ${#ALL_IDS[@]}"
# 10) Завантаження nexus.sh та інструкція
wget -q -O nexus.sh https://raw.githubusercontent.com/mgpwnz/Nexus/refs/heads/main/nexus.sh && chmod +x nexus.sh
echo "Щоб запустити ноди, використовуйте: ./nexus.sh"