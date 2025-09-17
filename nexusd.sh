#!/usr/bin/env bash
set -euo pipefail

# ==== Встановлюємо $HOME та середовище для systemd ====
export HOME="/root"
export XDG_RUNTIME_DIR="/run/user/0"
export TERM="xterm"

# ==== Перевірка залежностей ====
command -v tmux >/dev/null 2>&1 || { echo "❌ Потрібно встановити tmux"; exit 1; }
command -v script >/dev/null 2>&1 || { echo "❌ Потрібно встановити script"; exit 1; }

# ==== Налаштування ====
REPO_URL="https://github.com/nexus-xyz/nexus-cli.git"
PROJECT_DIR="$HOME/nexus-cli"
BUILD_DIR="$PROJECT_DIR/clients/cli"
ENV_FILE="$HOME/nexus-nodes.env"

# ==== Перевірка .env ====
if [ ! -f "$ENV_FILE" ]; then
  echo "[!] Файл $ENV_FILE не знайдено. Створюю..."
  {
    echo "NODE_IDS="
    echo "DIFFICULTY="
  } > "$ENV_FILE"
fi

# ==== Завантаження змінних ====
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

# ==== Пропозиція додати NODE_IDs ====
if [ "${SKIP_ADD_IDS_PROMPT:-}" != "true" ] && [[ -t 0 ]]; then
  echo
  echo "Хочеш додати ще ID до списку?"
  echo "  y — додати зараз"
  echo "  n — не додавати"
  echo "  s — більше не питати"
  read -t 15 -rp "[y/N/s] " ADD_IDS || ADD_IDS="n"

  case "$ADD_IDS" in
    [Yy])
      read -rp "Введи ID через кому (ID1,ID2,…): " NEW_IDS
      UPDATED_IDS="${NODE_IDS:+$NODE_IDS,}$NEW_IDS"
      if grep -q '^NODE_IDS=' "$ENV_FILE"; then
        sed -i "s|^NODE_IDS=.*|NODE_IDS=$UPDATED_IDS|" "$ENV_FILE"
      else
        echo "NODE_IDS=$UPDATED_IDS" >> "$ENV_FILE"
      fi
      NODE_IDS="$UPDATED_IDS"
      echo "[+] Оновлено NODE_IDS = $NODE_IDS"
      ;;
    [Ss])
      echo "SKIP_ADD_IDS_PROMPT=true" >> "$ENV_FILE"
      export SKIP_ADD_IDS_PROMPT=true
      echo "[i] Більше не питатиму про додавання ID."
      ADD_IDS="n"
      ;;
    *)
      ADD_IDS="n"
      ;;
  esac
else
  ADD_IDS="n"
fi

# ==== Зчитуємо масив та перевірка ====
IFS=',' read -r -a ARR <<< "${NODE_IDS:-}"
[ "${#ARR[@]}" -eq 0 ] && { echo "[-] Немає жодного Node ID."; exit 1; }
echo "[+] Node IDs: $NODE_IDS"

# ==== Примусове оновлення репо та збірка ====
if [ ! -d "$PROJECT_DIR" ]; then
  echo "[+] Репозиторій не знайдено. Клоную…"
  git clone "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"
echo "[+] Оновлення репозиторію до origin/main (git reset --hard)…"
git fetch origin
git reset --hard origin/main

echo "[+] Виконую збірку (release)…"
cd "$BUILD_DIR"
/root/.cargo/bin/cargo build --release

# ==== Визначаємо Difficulty ==== 
if [ -n "${DIFFICULTY:-}" ]; then
  Difficulty="$DIFFICULTY"
  echo "[i] Використовую DIFFICULTY з .env: $Difficulty"
else
  CPU_TOTAL=$(nproc)
  RAM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}') # KB
  RAM_GB=$((RAM_TOTAL / 1024 / 1024))

  if [ "$CPU_TOTAL" -ge 16 ] && [ "$RAM_GB" -ge 30 ]; then
    Difficulty="extra_large2"
  elif [ "$CPU_TOTAL" -ge 12 ] && [ "$RAM_GB" -ge 24 ]; then
    Difficulty="extra_large"
  elif [ "$CPU_TOTAL" -ge 8 ] && [ "$RAM_GB" -ge 16 ]; then
    Difficulty="large"
  elif [ "$CPU_TOTAL" -ge 6 ] && [ "$RAM_GB" -ge 12 ]; then
    Difficulty="medium"
  elif [ "$CPU_TOTAL" -ge 4 ] && [ "$RAM_GB" -ge 8 ]; then
    Difficulty="small_medium"
  else
    Difficulty="small"
  fi
  echo "[i] CPU: $CPU_TOTAL cores, RAM: ${RAM_GB}GB → Автовибір Difficulty = $Difficulty"
fi

# ==== Запускаємо кожну ноду в окремій tmux-сесії ====
for id in "${ARR[@]}"; do
  tmux kill-session -t "nexus-$id" 2>/dev/null || true
  echo "[+] Стартую nexus-$id в tmux (difficulty=$Difficulty)…"
  script -q -c "tmux new-session -d -s nexus-$id '$BUILD_DIR/target/release/nexus-network start --max-difficulty $Difficulty --node-id $id'" /dev/null
done

# ==== Перевірка та автоперезапуск ====
ALL_OK=true
for id in "${ARR[@]}"; do
  if ! tmux has-session -t "nexus-$id" 2>/dev/null; then
    echo "[!] nexus-$id не запустився!"
    ALL_OK=false
  fi
done
if [ "$ALL_OK" = false ]; then
  echo "[!] Деякі сесії не запустилися, перезапускаю через 5 с…"
  sleep 5
  exec "$HOME/nexus.sh"
fi

echo "[✓] Усі ноди запущені в tmux."
echo "Для підключення: tmux attach -t nexus-<ID>"
echo "Для відключення: Ctrl+b, потім d"