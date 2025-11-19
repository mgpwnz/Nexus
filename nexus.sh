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
export TMUX_TMPDIR="/run/tmux"
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

# ==== CPU конфігурація ====
TOTAL_CPUS=$(nproc)

echo
echo "==============================================="
echo "🧠 Всього потоків CPU на системі: $TOTAL_CPUS"
echo "==============================================="

# Якщо вже є значення в env — використовуємо його
if [ -n "${MAX_TOTAL_THREADS:-}" ]; then
  echo "[i] Поточне обмеження з env: MAX_TOTAL_THREADS=$MAX_TOTAL_THREADS"
else
  # Якщо немає — запитуємо користувача
  if [[ -t 0 ]]; then
    read -rp "Скільки потоків дозволено використовувати для Nexus? [1-$TOTAL_CPUS]: " MAX_THREADS_INPUT
  else
    MAX_THREADS_INPUT="$TOTAL_CPUS"
  fi

  # Валідація
  if ! [[ "$MAX_THREADS_INPUT" =~ ^[0-9]+$ ]] || (( MAX_THREADS_INPUT < 1 || MAX_THREADS_INPUT > TOTAL_CPUS )); then
    echo "[!] Некоректне число, використовую $TOTAL_CPUS"
    MAX_THREADS_INPUT="$TOTAL_CPUS"
  fi

  MAX_TOTAL_THREADS="$MAX_THREADS_INPUT"

  # Запис у .env
  if grep -q '^MAX_TOTAL_THREADS=' "$ENV_FILE"; then
    sed -i "s|^MAX_TOTAL_THREADS=.*|MAX_TOTAL_THREADS=$MAX_TOTAL_THREADS|" "$ENV_FILE"
  else
    echo "MAX_TOTAL_THREADS=$MAX_TOTAL_THREADS" >> "$ENV_FILE"
  fi

  echo "[+] Збережено в $ENV_FILE: MAX_TOTAL_THREADS=$MAX_TOTAL_THREADS"
fi

# ==== Автоматичний розподіл потоків між нодами ====
NODE_COUNT=${#ARR[@]}
if (( NODE_COUNT > MAX_TOTAL_THREADS )); then
  echo "[!] Кількість нод ($NODE_COUNT) більша за дозволені потоки ($MAX_TOTAL_THREADS). Деякі ноди ділитимуть потоки."
fi

THREADS_PER_NODE=$(( MAX_TOTAL_THREADS / NODE_COUNT ))
EXTRA_THREADS=$(( MAX_TOTAL_THREADS % NODE_COUNT ))

echo
echo "[i] Використовуємо всього потоків: $MAX_TOTAL_THREADS"
echo "[i] Нод: $NODE_COUNT"
echo "[i] Базово потоків на ноду: $THREADS_PER_NODE (з лишком $EXTRA_THREADS)"
echo "-----------------------------------------------"

# ==== Завершальні дії: tmux через script ====
for i in "${!ARR[@]}"; do
  id="${ARR[$i]}"

  # розподіляємо залишкові потоки між першими EXTRA_THREADS нодами
  if (( i < EXTRA_THREADS )); then
    THREADS=$(( THREADS_PER_NODE + 1 ))
  else
    THREADS=$THREADS_PER_NODE
  fi

  tmux kill-session -t "nexus-$id" 2>/dev/null || true
  echo "[+] Стартую nexus-$id з $THREADS потоками…"

  script -q -c "tmux new-session -d -s nexus-$id '$BUILD_DIR/target/release/nexus-network start --node-id $id --max-threads $THREADS'" /dev/null
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

