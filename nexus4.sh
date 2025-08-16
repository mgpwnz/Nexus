#!/usr/bin/env bash
set -euo pipefail

# ==== Логування (лише фонова/таймерна робота) ====
LOGFILE=/var/log/nexus-tmux.log

if [[ -t 1 ]]; then
  # ми в інтерактивному терміналі — показуємо і лог
  exec > >(tee -a "$LOGFILE") 2>&1
else
  # без терміналу (systemd) — просто в лог
  exec >> "$LOGFILE" 2>&1
fi


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
  echo "NODE_IDS=" > "$ENV_FILE"
fi

# ==== Завантаження змінних ====
if [ -f "$ENV_FILE" ]; then
  # автоматично робимо всі змінні експортованими
  set -a
  # shell-білдінг: імпортуємо всі змінні з файлу
  source "$ENV_FILE"
  set +a
fi
# ==== Відкат автозапуску (видалення systemd таймера, якщо залишився) ====
SERVICE_FILE="/etc/systemd/system/nexus-auto-update.service"
TIMER_FILE="/etc/systemd/system/nexus-auto-update.timer"

if [ -f "$SERVICE_FILE" ] || [ -f "$TIMER_FILE" ]; then
  echo "[i] Виявлено залишки автозапуску. Видаляю nexus-auto-update.service/timer…"
  systemctl stop nexus-auto-update.timer 2>/dev/null || true
  systemctl disable nexus-auto-update.timer 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  echo "[✓] Автозапуск видалено."
fi

# ==== Пропозиція додати NODE_IDs ====
# запит тільки якщо прапор SKIP_ADD_IDS_PROMPT не встановлено
if [ "${SKIP_ADD_IDS_PROMPT:-}" != "true" ] && [[ -t 0 ]]; then
  echo
  echo "Хочеш додати ще ID до списку?"
  echo "  y — додати зараз"
  echo "  n — не додавати"
  echo "  s — більше не питати"
  read -t 15 -rp "[y/N/s] " ADD_IDS || ADD_IDS="n"

  case "$ADD_IDS" in
    [Yy])
      # користувач хоче додати
      read -rp "Введи ID через кому (ID1,ID2,…): " NEW_IDS
      UPDATED_IDS="${NODE_IDS:+$NODE_IDS,}$NEW_IDS"
      # оновлюємо або додаємо рядок у env-файлі
      if grep -q '^NODE_IDS=' "$ENV_FILE"; then
        sed -i "s|^NODE_IDS=.*|NODE_IDS=$UPDATED_IDS|" "$ENV_FILE"
      else
        echo "NODE_IDS=$UPDATED_IDS" >> "$ENV_FILE"
      fi
      NODE_IDS="$UPDATED_IDS"
      echo "[+] Оновлено NODE_IDS = $NODE_IDS"
      ;;
    [Ss])
      # прапор “більше не питати”
      echo "SKIP_ADD_IDS_PROMPT=true" >> "$ENV_FILE"
      export SKIP_ADD_IDS_PROMPT=true
      echo "[i] Більше не питатиму про додавання ID."
      ADD_IDS="n"
      ;;
    *)
      # будь-який інший варіант — нічого не змінюємо
      ADD_IDS="n"
      ;;
  esac
else
  # або вже встановлено SKIP, або неінтерактивний режим
  ADD_IDS="n"
fi


# ==== Зчитуємо масив та перевірка ====
IFS=',' read -r -a ARR <<< "$NODE_IDS"
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


# ==== Завершальні дії: tmux через script ====
# ==== Встановлюємо кількість потоків для однієї ноди ====
tr=4

# ==== Перевіряємо доступні CPU ====
CPU_TOTAL=$(nproc)
MAX_PROCS=$(( CPU_TOTAL / tr ))

if [ "$MAX_PROCS" -eq 0 ]; then
  echo "❌ Недостатньо CPU для запуску навіть однієї ноди (потрібно $tr потоків)."
  exit 1
fi

echo "[i] У системі $CPU_TOTAL потоків CPU, можна запустити максимум $MAX_PROCS нод по $tr потоків."

# ==== Вибираємо стільки ID, скільки можемо запустити ====
LIMITED_IDS=("${ARR[@]:0:$MAX_PROCS}")

# ==== Запускаємо кожну ноду в окремій tmux-сесії ====
for id in "${LIMITED_IDS[@]}"; do
  tmux kill-session -t "nexus-$id" 2>/dev/null || true
  echo "[+] Стартую nexus-$id в tmux (threads=$tr)…"
  script -q -c "tmux new-session -d -s nexus-$id '$BUILD_DIR/target/release/nexus-network start --node-id $id --max-threads $tr'" /dev/null
done

# ==== Якщо було більше ID, ніж можна запустити ====
if [ "${#ARR[@]}" -gt "$MAX_PROCS" ]; then
  echo "[!] У списку було ${#ARR[@]} нод, але реально запущено тільки $MAX_PROCS через CPU-обмеження."
  echo "[!] Надлишкові ID: ${ARR[@]:$MAX_PROCS}"
fi

# ==== Перевірка та автоперезапуск ====
ALL_OK=true
for id in "${LIMITED_IDS[@]}"; do
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

