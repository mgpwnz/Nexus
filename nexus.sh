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

# ==== Видалення старого user-сервісу (як є) ====
OLD_DIR="$HOME/.config/systemd/user"
[ -f "$OLD_DIR/nexus-auto-update.service" ] || [ -f "$OLD_DIR/nexus-auto-update.timer" ] && {
  echo "[i] Видаляю старий user-сервіс…"
  systemctl --user stop nexus-auto-update.timer 2>/dev/null || true
  systemctl --user disable nexus-auto-update.timer 2>/dev/null || true
  rm -f "$OLD_DIR/nexus-auto-update."{service,timer}
  systemctl --user daemon-reload
  echo "[✓] Видалено."
}

# ==== Налаштування системного таймера ====
if [ "${DISABLE_NEXUS_TIMER:-}" != "true" ]; then
  if [[ -t 0 ]]; then
    echo
    echo "====================================================="
    echo "Налаштувати автозапуск nexus.sh раз на 2 дні?"
    echo "(за 15 с без відповіді — відмова)"
    echo "====================================================="
    read -t 15 -rp "Налаштувати таймер? [y/N] " SETUP_TIMER || SETUP_TIMER="n"
  else
    SETUP_TIMER="n"
  fi

  if [[ "$SETUP_TIMER" =~ ^[Yy]$ ]]; then
    echo "[+] Створюю systemd таймер (системний)…"
    SERVICE_FILE="/etc/systemd/system/nexus-auto-update.service"
    TIMER_FILE="/etc/systemd/system/nexus-auto-update.timer"

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Автозапуск Nexus CLI

[Service]
Type=oneshot
ExecStart=/root/nexus.sh
StandardOutput=journal
StandardError=journal
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

    systemctl daemon-reload
    systemctl enable --now nexus-auto-update.timer
    echo "[✓] Таймер налаштовано!"
  else
    echo "DISABLE_NEXUS_TIMER=true" >> "$ENV_FILE"
    export DISABLE_NEXUS_TIMER=true
    echo "[i] Автозапуск відключено."
  fi
fi

# ==== Пропозиція додати NODE_IDs ====
if [[ -t 0 ]]; then
  read -t 15 -rp "Хочеш додати ще ID до списку? [y/N] " ADD_IDS || ADD_IDS="n"
else
  ADD_IDS="n"
fi

NODE_IDS="${NODE_IDS:-}"
if [[ "$ADD_IDS" =~ ^[Yy]$ ]]; then
  read -rp "Введи ID через кому (ID1,ID2,…): " NEW_IDS
  UPDATED_IDS="${NODE_IDS:+$NODE_IDS,}$NEW_IDS"
  echo "NODE_IDS=$UPDATED_IDS" > "$ENV_FILE"
  NODE_IDS="$UPDATED_IDS"
  echo "[+] Оновлено NODE_IDS = $NODE_IDS"
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
for id in "${ARR[@]}"; do
  tmux kill-session -t "nexus-$id" 2>/dev/null || true
  echo "[+] Стартую nexus-$id в tmux…"
  script -q -c "tmux new-session -d -s nexus-$id '$BUILD_DIR/target/release/nexus-network start --node-id $id'" /dev/null
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

