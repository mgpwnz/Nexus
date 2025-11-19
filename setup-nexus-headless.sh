#!/usr/bin/env bash
set -euo pipefail

# ==== Конфігурація ====
WRAPPER="/root/nexus-headless-wrapper.sh"
SERVICE="/etc/systemd/system/nexus-headless.service"
BUILD_DIR="/root/nexus-cli/clients/cli"
ENV_FILE="/root/nexus-nodes.env"

# ==== Створення wrapper-скрипта ====
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/nexus-nodes.env"
BUILD_DIR="/root/nexus-cli/clients/cli"

# ==== Завантаження змінних з .env ====
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "[-] nexus-nodes.env не знайдено!"
    exit 1
fi

# ==== Перетворення NODE_IDS в масив ====
IFS=',' read -r -a ARR <<< "${NODE_IDS:-}"
if [ "${#ARR[@]}" -eq 0 ]; then
    echo "[-] NODE_IDS порожній!"
    exit 1
fi

# ==== Розподіл потоків ====
NODE_COUNT=${#ARR[@]}
THREADS_PER_NODE=$(( MAX_TOTAL_THREADS / NODE_COUNT ))
EXTRA_THREADS=$(( MAX_TOTAL_THREADS % NODE_COUNT ))

# ==== Запуск кожної ноди у headless-режимі ====
for i in "${!ARR[@]}"; do
    id="${ARR[$i]}"
    if (( i < EXTRA_THREADS )); then
        THREADS=$(( THREADS_PER_NODE + 1 ))
    else
        THREADS=$THREADS_PER_NODE
    fi

    # Якщо процес уже запущений, вбиваємо його
    pkill -f "nexus-network start --node-id $id" || true

    # Стартуємо ноду у headless
    "$BUILD_DIR/target/release/nexus-network" start --node-id "$id" --max-threads "$THREADS" --headless &
done

# Чекаємо всі фонові процеси
wait
EOF

chmod +x "$WRAPPER"
echo "[✓] Wrapper створено: $WRAPPER"

# ==== Створення systemd-сервісу ====
cat > "$SERVICE" <<EOF
[Unit]
Description=Nexus headless nodes autostart
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BUILD_DIR
ExecStart=$WRAPPER
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "[✓] Systemd-сервіс створено: $SERVICE"

# ==== Активація та запуск ====
systemctl daemon-reload
systemctl enable nexus-headless.service
systemctl start nexus-headless.service

echo "[✓] Сервіс запущено та активовано: nexus-headless.service"
echo "Перевірка статусу: systemctl status nexus-headless.service"